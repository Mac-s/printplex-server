import XCTVapor
import PrintPlexCore
@testable import PrintPlexServerApp

/// Covers the dashboard login (session-cookie auth) and the API key (used by
/// other services like the ForgeCore relay or the native client). Auth is
/// bypassed by default in `.testing` (see `Application.authEnforcementEnabled`)
/// so every other test suite keeps calling the API unauthenticated — this
/// file explicitly re-enables it to test the real gating.
final class AuthTests: XCTestCase {
    var app: Application!
    var mediaDir: URL!
    var dataDir: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
        mediaDir = base.appendingPathComponent("printplex-auth-media-\(UUID().uuidString)")
        dataDir = base.appendingPathComponent("printplex-auth-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        setenv("PRINTPLEX_MEDIA_PATH", mediaDir.path, 1)
        setenv("PRINTPLEX_DATA_PATH", dataDir.path, 1)
        setenv("PRINTPLEX_DB_IN_MEMORY", "1", 1)
        setenv("PRINTPLEX_SCAN_INTERVAL_MIN", "0", 1)
        setenv("SHOPIFY_STORE_DOMAIN", "", 1)
        setenv("SHOPIFY_ACCESS_TOKEN", "", 1)
        unsetenv("PRINTPLEX_ADMIN_USERNAME")
        unsetenv("PRINTPLEX_ADMIN_PASSWORD")

        app = try await Application.make(.testing)
        try await configure(app)
        app.authEnforcementEnabled = true
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
        try? FileManager.default.removeItem(at: mediaDir)
        try? FileManager.default.removeItem(at: dataDir)
    }

    // MARK: - Helpers

    @discardableResult
    private func login(username: String = "max", password: String = "supersecret1") async throws -> HTTPCookies {
        var cookies: HTTPCookies?
        try await app.test(.POST, "api/auth/setup", beforeRequest: { req in
            try req.content.encode(AuthCredentialsRequest(username: username, password: password))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            cookies = res.headers.setCookie
        })
        return try XCTUnwrap(cookies)
    }

    // MARK: - Gating

    func testProtectedEndpointRejectsUnauthenticatedRequests() async throws {
        try await app.test(.GET, "api/projects") { res async in
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    func testHealthAndAuthStatusStayUnauthenticated() async throws {
        try await app.test(.GET, "health") { res async in
            XCTAssertEqual(res.status, .ok)
        }
        try await app.test(.GET, "api/auth/status") { res async throws in
            XCTAssertEqual(res.status, .ok)
            let status = try res.content.decode(AuthStatusResponse.self)
            XCTAssertTrue(status.setupRequired)
            XCTAssertFalse(status.authenticated)
        }
    }

    // MARK: - Setup / login / logout

    func testSetupCreatesAccountLogsInAndCanBeUsedOnlyOnce() async throws {
        let cookies = try await login()

        try await app.test(.GET, "api/auth/status", beforeRequest: { req in
            req.headers.cookie = cookies
        }, afterResponse: { res async throws in
            let status = try res.content.decode(AuthStatusResponse.self)
            XCTAssertFalse(status.setupRequired)
            XCTAssertTrue(status.authenticated)
        })

        // Second setup attempt is rejected, even with different credentials.
        try await app.test(.POST, "api/auth/setup", beforeRequest: { req in
            try req.content.encode(AuthCredentialsRequest(username: "someone-else", password: "whatever123"))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .forbidden)
        })
    }

    func testSetupRejectsShortPassword() async throws {
        try await app.test(.POST, "api/auth/setup", beforeRequest: { req in
            try req.content.encode(AuthCredentialsRequest(username: "max", password: "short"))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testLoginWithCorrectCredentialsGrantsAccessToProtectedRoutes() async throws {
        try await login(username: "max", password: "supersecret1")
        try await app.test(.POST, "api/auth/logout")

        var cookies: HTTPCookies?
        try await app.test(.POST, "api/auth/login", beforeRequest: { req in
            try req.content.encode(AuthCredentialsRequest(username: "max", password: "supersecret1"))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            cookies = res.headers.setCookie
        })

        try await app.test(.GET, "api/projects", beforeRequest: { req in
            req.headers.cookie = try XCTUnwrap(cookies)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })
    }

    func testLoginWithWrongPasswordIsRejected() async throws {
        try await login(username: "max", password: "supersecret1")

        try await app.test(.POST, "api/auth/login", beforeRequest: { req in
            try req.content.encode(AuthCredentialsRequest(username: "max", password: "wrong-password"))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    func testLogoutRevokesAccess() async throws {
        let cookies = try await login()

        try await app.test(.POST, "api/auth/logout", beforeRequest: { req in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })

        try await app.test(.GET, "api/projects", beforeRequest: { req in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    // MARK: - Change password

    func testChangePasswordThenLoginWithNewPassword() async throws {
        let cookies = try await login(username: "max", password: "supersecret1")

        try await app.test(.POST, "api/auth/change-password", beforeRequest: { req in
            req.headers.cookie = cookies
            try req.content.encode(ChangePasswordRequest(currentPassword: "supersecret1", newPassword: "brandnewpass1"))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })

        try await app.test(.POST, "api/auth/login", beforeRequest: { req in
            try req.content.encode(AuthCredentialsRequest(username: "max", password: "supersecret1"))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })

        try await app.test(.POST, "api/auth/login", beforeRequest: { req in
            try req.content.encode(AuthCredentialsRequest(username: "max", password: "brandnewpass1"))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })
    }

    func testChangePasswordRejectsWrongCurrentPassword() async throws {
        let cookies = try await login()

        try await app.test(.POST, "api/auth/change-password", beforeRequest: { req in
            req.headers.cookie = cookies
            try req.content.encode(ChangePasswordRequest(currentPassword: "not-the-password", newPassword: "brandnewpass1"))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    // MARK: - API key

    func testApiKeyHeaderGrantsAccessWithoutASession() async throws {
        let cookies = try await login()

        var apiKey: String?
        try await app.test(.GET, "api/auth/api-key", beforeRequest: { req in
            req.headers.cookie = cookies
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            apiKey = try res.content.decode(ApiKeyResponse.self).apiKey
        })
        let key = try XCTUnwrap(apiKey)
        XCTAssertTrue(key.hasPrefix("ppx_"))

        // No session cookie at all here — only the API key header.
        try await app.test(.GET, "api/projects", beforeRequest: { req in
            req.headers.add(name: "X-API-Key", value: key)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })
    }

    func testWrongApiKeyIsRejected() async throws {
        try await login()

        try await app.test(.GET, "api/projects", beforeRequest: { req in
            req.headers.add(name: "X-API-Key", value: "ppx_not-the-real-key")
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    func testRegenerateApiKeyInvalidatesThePreviousOne() async throws {
        let cookies = try await login()

        var firstKey: String?
        try await app.test(.GET, "api/auth/api-key", beforeRequest: { req in
            req.headers.cookie = cookies
        }, afterResponse: { res async throws in
            firstKey = try res.content.decode(ApiKeyResponse.self).apiKey
        })

        var secondKey: String?
        try await app.test(.POST, "api/auth/api-key/regenerate", beforeRequest: { req in
            req.headers.cookie = cookies
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            secondKey = try res.content.decode(ApiKeyResponse.self).apiKey
        })

        XCTAssertNotEqual(firstKey, secondKey)

        try await app.test(.GET, "api/projects", beforeRequest: { req in
            req.headers.add(name: "X-API-Key", value: try XCTUnwrap(firstKey))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
        try await app.test(.GET, "api/projects", beforeRequest: { req in
            req.headers.add(name: "X-API-Key", value: try XCTUnwrap(secondKey))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })
    }

    // MARK: - Env-var seeding

    func testAdminAccountSeededFromEnvironmentOnFirstBoot() async throws {
        // A fresh app (own DB) with admin credentials pre-set via env vars,
        // mirroring how docker-compose would seed the very first boot.
        setenv("PRINTPLEX_ADMIN_USERNAME", "envadmin", 1)
        setenv("PRINTPLEX_ADMIN_PASSWORD", "envpassword1", 1)
        setenv("PRINTPLEX_DATA_PATH", dataDir.appendingPathComponent("seeded").path, 1)

        let seededApp = try await Application.make(.testing)
        try await configure(seededApp)
        seededApp.authEnforcementEnabled = true

        try await seededApp.test(.GET, "api/auth/status") { res async throws in
            let status = try res.content.decode(AuthStatusResponse.self)
            XCTAssertFalse(status.setupRequired)
        }
        try await seededApp.test(.POST, "api/auth/login", beforeRequest: { req in
            try req.content.encode(AuthCredentialsRequest(username: "envadmin", password: "envpassword1"))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })

        try await seededApp.asyncShutdown()
        setenv("PRINTPLEX_DATA_PATH", dataDir.path, 1)
        unsetenv("PRINTPLEX_ADMIN_USERNAME")
        unsetenv("PRINTPLEX_ADMIN_PASSWORD")
    }
}
