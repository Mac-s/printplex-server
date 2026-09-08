import XCTVapor
import PrintPlexCore
@testable import PrintPlexServerApp

final class MCPTests: XCTestCase {
    var app: Application!
    var mediaDir: URL!
    var dataDir: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
        mediaDir = base.appendingPathComponent("printplex-mcp-media-\(UUID().uuidString)")
        dataDir = base.appendingPathComponent("printplex-mcp-data-\(UUID().uuidString)")
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
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
        try? FileManager.default.removeItem(at: mediaDir)
        try? FileManager.default.removeItem(at: dataDir)
    }

    // MARK: - Helpers

    private func rpc(_ body: [String: Any]) throws -> ByteBuffer {
        ByteBuffer(data: try JSONSerialization.data(withJSONObject: body))
    }

    private func callTool(_ name: String, arguments: [String: Any] = [:]) async throws -> XCTHTTPResponse {
        var captured: XCTHTTPResponse!
        try await app.test(.POST, "api/mcp", beforeRequest: { req in
            req.headers.replaceOrAdd(name: "Content-Type", value: "application/json")
            req.headers.replaceOrAdd(name: "Accept", value: "application/json")
            req.body = try rpc([
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": name, "arguments": arguments],
            ])
        }, afterResponse: { res async throws in
            captured = res
        })
        return captured
    }

    // MARK: - Tests

    func testMcpEndpointRequiresAuth() async throws {
        app.authEnforcementEnabled = true
        try await app.test(.POST, "api/mcp", beforeRequest: { req in
            req.headers.replaceOrAdd(name: "Content-Type", value: "application/json")
            req.headers.replaceOrAdd(name: "Accept", value: "application/json")
            req.body = try rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]])
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    func testInitializeHandshakeSucceeds() async throws {
        try await app.test(.POST, "api/mcp", beforeRequest: { req in
            req.headers.replaceOrAdd(name: "Content-Type", value: "application/json")
            req.headers.replaceOrAdd(name: "Accept", value: "application/json")
            req.body = try rpc([
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18",
                    "capabilities": [String: Any](),
                    "clientInfo": ["name": "test-client", "version": "1.0"],
                ],
            ])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("\"protocolVersion\""))
        })
    }

    /// Regression test: the MCP `Server` is stateless per-request (a fresh
    /// instance is built for every HTTP call, see `makeMCPTransport`), so a
    /// second independent client's `initialize` — e.g. a reconnect, or a
    /// second agent — must succeed too, not fail with "Server is already
    /// initialized" the way it would if one `Server` were shared across
    /// every request.
    func testInitializeSucceedsForASecondIndependentClient() async throws {
        func initialize() async throws -> XCTHTTPResponse {
            var captured: XCTHTTPResponse!
            try await app.test(.POST, "api/mcp", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "Content-Type", value: "application/json")
                req.headers.replaceOrAdd(name: "Accept", value: "application/json")
                req.body = try rpc([
                    "jsonrpc": "2.0", "id": 1, "method": "initialize",
                    "params": [
                        "protocolVersion": "2025-06-18",
                        "capabilities": [String: Any](),
                        "clientInfo": ["name": "test-client", "version": "1.0"],
                    ],
                ])
            }, afterResponse: { res async throws in
                captured = res
            })
            return captured
        }

        let first = try await initialize()
        XCTAssertEqual(first.status, .ok)
        XCTAssertTrue(first.body.string.contains("\"protocolVersion\""))

        let second = try await initialize()
        XCTAssertEqual(second.status, .ok)
        XCTAssertTrue(second.body.string.contains("\"protocolVersion\""))
        XCTAssertFalse(second.body.string.contains("already initialized"))
    }

    func testToolsListReturnsRegisteredProjectTools() async throws {
        try await app.test(.POST, "api/mcp", beforeRequest: { req in
            req.headers.replaceOrAdd(name: "Content-Type", value: "application/json")
            req.headers.replaceOrAdd(name: "Accept", value: "application/json")
            req.body = try rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("\"list_projects\""))
        })
    }

    func testUnknownToolReturnsErrorResult() async throws {
        let res = try await callTool("nonexistent_tool")
        XCTAssertEqual(res.status, .ok)
        XCTAssertTrue(res.body.string.contains("\"isError\":true"))
    }

    func testListProjectsToolReturnsEmptyArrayWhenNoProjects() async throws {
        let res = try await callTool("list_projects")
        XCTAssertEqual(res.status, .ok)
        XCTAssertFalse(res.body.string.contains("\"isError\":true"))
        XCTAssertTrue(res.body.string.contains("\"structuredContent\":[]"))
    }

    func testGetProjectToolReturns404ForUnknownId() async throws {
        let res = try await callTool("get_project", arguments: ["projectId": UUID().uuidString])
        XCTAssertEqual(res.status, .ok)
        XCTAssertTrue(res.body.string.contains("\"isError\":true"))
        XCTAssertTrue(res.body.string.contains("Projet introuvable"))
    }

    func testListFilesToolReturnsEmptyArrayWhenNoFiles() async throws {
        let res = try await callTool("list_files")
        XCTAssertEqual(res.status, .ok)
        XCTAssertFalse(res.body.string.contains("\"isError\":true"))
        XCTAssertTrue(res.body.string.contains("\"structuredContent\":[]"))
    }

    func testGetScanStatusToolReturnsStatus() async throws {
        let res = try await callTool("get_scan_status")
        XCTAssertEqual(res.status, .ok)
        XCTAssertTrue(res.body.string.contains("\"isScanning\""))
    }

    func testListLibrariesToolReturnsEmptyArrayWhenNoLibraries() async throws {
        let res = try await callTool("list_libraries")
        XCTAssertEqual(res.status, .ok)
        XCTAssertFalse(res.body.string.contains("\"isError\":true"))
        XCTAssertTrue(res.body.string.contains("\"structuredContent\":[]"))
    }

    func testCreateLibraryToolReturnsISO8601DateAdded() async throws {
        // Regression test: a bare JSONEncoder/JSONDecoder in the MCP bridge
        // defaults to .deferredToDate (a raw Double), diverging from the
        // .iso8601 strategy every REST route uses via
        // ContentConfiguration.default(). dateAdded is populated
        // automatically on creation, so an ISO8601 string here (starting
        // with "20...") would never appear if this regressed.
        let res = try await callTool("create_library", arguments: ["name": "Bibliothèque", "relativePath": ""])
        XCTAssertEqual(res.status, .ok)
        XCTAssertFalse(res.body.string.contains("\"isError\":true"))
        XCTAssertTrue(res.body.string.contains("\"dateAdded\":\"20"))
    }

    func testDeleteLibraryToolReturns404ForUnknownId() async throws {
        let res = try await callTool("delete_library", arguments: ["libraryId": UUID().uuidString])
        XCTAssertEqual(res.status, .ok)
        XCTAssertTrue(res.body.string.contains("\"isError\":true"))
    }

    func testCreatePrinterToolPersistsPrinter() async throws {
        let res = try await callTool("create_printer", arguments: [
            "name": "Test Printer", "buildX": 220, "buildY": 220, "buildZ": 250,
            "perimeterSpeedMMPS": 40, "infillSpeedMMPS": 80, "nozzleDiameterMM": 0.4,
            "defaultLayerHeightMM": 0.2, "supportsPercent": 10, "purgePercent": 5, "speedEfficiency": 0.85,
        ])
        XCTAssertEqual(res.status, .ok)
        XCTAssertFalse(res.body.string.contains("\"isError\":true"))
        XCTAssertTrue(res.body.string.contains("Test Printer"))
    }

    func testListMaterialsToolReturnsSeededCatalog() async throws {
        let res = try await callTool("list_materials")
        XCTAssertEqual(res.status, .ok)
        XCTAssertFalse(res.body.string.contains("\"isError\":true"))
        // seedReferenceDataIfNeeded() seeds PrintMaterial.defaults at boot.
        XCTAssertTrue(res.body.string.contains("\"pricePerKg\""))
    }

    func testGetShopifySettingsToolNeverReturnsAccessToken() async throws {
        // Directly seed a token via the settings row, bypassing the API, so
        // this test would fail loudly if the redaction were ever removed.
        let row = try await AppSettingsModel.find(AppSettingsModel.singletonID, on: app.db)!
        row.shopifyStoreDomain = "maboutique.myshopify.com"
        row.shopifyAccessToken = "shpat_supersecret"
        try await row.save(on: app.db)

        let res = try await callTool("get_shopify_settings")
        XCTAssertEqual(res.status, .ok)
        XCTAssertFalse(res.body.string.contains("shpat_supersecret"))
        XCTAssertTrue(res.body.string.contains("maboutique.myshopify.com"))

        // update_shopify_settings must redact the token just as much as
        // get_shopify_settings, even though the caller supplied it — echoing
        // it back a second time would put a live API secret into the tool
        // result transcript.
        let updateRes = try await callTool("update_shopify_settings", arguments: [
            "storeDomain": "maboutique.myshopify.com", "accessToken": "shpat_supersecret",
        ])
        XCTAssertEqual(updateRes.status, .ok)
        XCTAssertFalse(updateRes.body.string.contains("shpat_supersecret"))
        XCTAssertTrue(updateRes.body.string.contains("maboutique.myshopify.com"))
    }

    func testListShopifyProductsToolReturnsServiceUnavailableWhenNotConfigured() async throws {
        // SHOPIFY_STORE_DOMAIN/ACCESS_TOKEN are empty in setUp(), so no
        // ShopifyCache is created at boot — this must surface as a tool
        // error, not a crash.
        let res = try await callTool("list_shopify_products")
        XCTAssertEqual(res.status, .ok)
        XCTAssertTrue(res.body.string.contains("\"isError\":true"))
        XCTAssertTrue(res.body.string.contains("Shopify non configuré"))
    }

    func testGetForgecorePendingToolReturnsEmptyArrayWhenNothingPending() async throws {
        let res = try await callTool("get_forgecore_pending")
        XCTAssertEqual(res.status, .ok)
        XCTAssertFalse(res.body.string.contains("\"isError\":true"))
    }

    func testToolsListIncludesEveryRegisteredGroup() async throws {
        try await app.test(.POST, "api/mcp", beforeRequest: { req in
            req.headers.replaceOrAdd(name: "Content-Type", value: "application/json")
            req.headers.replaceOrAdd(name: "Accept", value: "application/json")
            req.body = try rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            for name in ["list_projects", "list_files", "trigger_scan", "list_libraries",
                         "list_printers", "list_materials", "get_settings",
                         "list_shopify_products", "get_forgecore_pending"] {
                XCTAssertTrue(res.body.string.contains("\"\(name)\""), "missing tool: \(name)")
            }
        })
    }

    func testUpdateProjectToolPersistsChanges() async throws {
        // Seed one project directly via a scan of a real fixture, exactly
        // like ServerTests does, so the write's effect can be confirmed by
        // reading the DB directly.
        let stlPath = mediaDir.appendingPathComponent("Groupe/Figurine/piece.stl")
        try FileManager.default.createDirectory(at: stlPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: stlPath)
        // Libraries are Plex-style: nothing is scanned until at least one is
        // configured (see ServerTests.addLibrary()).
        try await app.test(.POST, "api/libraries", beforeRequest: { req in
            try req.content.encode(LibraryCreateRequest(name: "Bibliothèque", relativePath: ""))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })
        await app.scanService.runScan()

        let project = try await ProjectModel.query(on: app.db).first()
        let projectId = try XCTUnwrap(project?.requireID()).uuidString

        let res = try await callTool("update_project", arguments: ["projectId": projectId, "notes": "Testé via MCP"])
        XCTAssertEqual(res.status, .ok)
        XCTAssertFalse(res.body.string.contains("\"isError\":true"))

        let reloaded = try await ProjectModel.find(UUID(uuidString: projectId), on: app.db)
        XCTAssertEqual(reloaded?.notes, "Testé via MCP")
    }
}
