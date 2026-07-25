import XCTVapor
import PrintPlexCore
@testable import PrintPlexServerApp

/// Covers the Plex-style "libraries" feature: the container mounts one
/// generic media root (`PRINTPLEX_MEDIA_PATH`), and specific folders under
/// it are added/removed as scan roots via `/api/libraries` instead of a
/// single path fixed at boot.
final class LibraryTests: XCTestCase {
    var app: Application!
    var mediaDir: URL!
    var dataDir: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
        mediaDir = base.appendingPathComponent("printplex-lib-media-\(UUID().uuidString)")
        dataDir = base.appendingPathComponent("printplex-lib-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        setenv("PRINTPLEX_MEDIA_PATH", mediaDir.path, 1)
        setenv("PRINTPLEX_DATA_PATH", dataDir.path, 1)
        setenv("PRINTPLEX_DB_IN_MEMORY", "1", 1)
        setenv("PRINTPLEX_SCAN_INTERVAL_MIN", "0", 1)
        setenv("SHOPIFY_STORE_DOMAIN", "", 1)
        setenv("SHOPIFY_ACCESS_TOKEN", "", 1)

        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
        try? FileManager.default.removeItem(at: mediaDir)
        try? FileManager.default.removeItem(at: dataDir)
    }

    private func makeProjectFolder(_ relativePath: String, name: String) throws {
        let dir = mediaDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try TestZip.cube3MF().write(to: dir.appendingPathComponent("piece.3mf"))
        try Data("{\"nom\": \"\(name)\"}".utf8).write(to: dir.appendingPathComponent("info.json"))
    }

    // MARK: - CRUD

    func testEmptyByDefault() async throws {
        try await app.test(.GET, "api/libraries") { res async throws in
            XCTAssertEqual(res.status, .ok)
            let libraries = try res.content.decode([LibraryDTO].self)
            XCTAssertTrue(libraries.isEmpty)
        }
    }

    func testScanWithNoLibrariesConfiguredIsANoOp() async throws {
        // Plex-style: nothing happens until at least one library exists.
        try await app.test(.POST, "api/scan?wait=true") { res async throws in
            let status = try res.content.decode(ScanStatusResponse.self)
            XCTAssertFalse(status.isScanning)
            XCTAssertEqual(status.projectCount, 0)
        }
    }

    func testCreateRejectsMissingFolder() async throws {
        try await app.test(.POST, "api/libraries", beforeRequest: { req in
            try req.content.encode(LibraryCreateRequest(name: "Figurines", relativePath: "NExistePas"))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testCreateRejectsEscapingPath() async throws {
        try await app.test(.POST, "api/libraries", beforeRequest: { req in
            try req.content.encode(LibraryCreateRequest(name: "Hors média", relativePath: "../../etc"))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testCreateRejectsDuplicateFolder() async throws {
        try FileManager.default.createDirectory(
            at: mediaDir.appendingPathComponent("Figurines"), withIntermediateDirectories: true)

        try await app.test(.POST, "api/libraries", beforeRequest: { req in
            try req.content.encode(LibraryCreateRequest(name: "Figurines", relativePath: "Figurines"))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })
        try await app.test(.POST, "api/libraries", beforeRequest: { req in
            try req.content.encode(LibraryCreateRequest(name: "Doublon", relativePath: "Figurines"))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .conflict)
        })
    }

    func testCreateAndDelete() async throws {
        try FileManager.default.createDirectory(
            at: mediaDir.appendingPathComponent("Posters"), withIntermediateDirectories: true)

        var libraryID: UUID?
        try await app.test(.POST, "api/libraries", beforeRequest: { req in
            try req.content.encode(LibraryCreateRequest(name: "Posters", relativePath: "Posters"))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let library = try res.content.decode(LibraryDTO.self)
            XCTAssertEqual(library.name, "Posters")
            XCTAssertEqual(library.relativePath, "Posters")
            libraryID = library.id
        })
        let id = try XCTUnwrap(libraryID)

        try await app.test(.GET, "api/libraries") { res async throws in
            let libraries = try res.content.decode([LibraryDTO].self)
            XCTAssertEqual(libraries.count, 1)
        }

        try await app.test(.DELETE, "api/libraries/\(id)") { res async in
            XCTAssertEqual(res.status, .noContent)
        }
        try await app.test(.GET, "api/libraries") { res async throws in
            let libraries = try res.content.decode([LibraryDTO].self)
            XCTAssertTrue(libraries.isEmpty)
        }
    }

    // MARK: - Browse (folder picker)

    func testBrowseListsSubdirectoriesOnly() async throws {
        try FileManager.default.createDirectory(
            at: mediaDir.appendingPathComponent("Figurines"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: mediaDir.appendingPathComponent("Posters"), withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: mediaDir.appendingPathComponent("readme.txt"))

        try await app.test(.GET, "api/libraries/browse") { res async throws in
            XCTAssertEqual(res.status, .ok)
            let browse = try res.content.decode(BrowseResponse.self)
            XCTAssertEqual(browse.path, "")
            XCTAssertNil(browse.parentPath)
            XCTAssertEqual(browse.directories.sorted(), ["Figurines", "Posters"])
        }
    }

    func testBrowseNestedPathReportsParent() async throws {
        try FileManager.default.createDirectory(
            at: mediaDir.appendingPathComponent("Figurines/Dragons"), withIntermediateDirectories: true)

        try await app.test(.GET, "api/libraries/browse?path=Figurines") { res async throws in
            let browse = try res.content.decode(BrowseResponse.self)
            XCTAssertEqual(browse.path, "Figurines")
            XCTAssertEqual(browse.parentPath, "")
            XCTAssertEqual(browse.directories, ["Dragons"])
        }
    }

    func testBrowseRejectsPathEscape() async throws {
        try await app.test(.GET, "api/libraries/browse?path=..%2F..%2Fetc") { res async in
            XCTAssertEqual(res.status, .badRequest)
        }
    }

    func testBrowseMissingFolderReturns404() async throws {
        try await app.test(.GET, "api/libraries/browse?path=NExistePas") { res async in
            XCTAssertEqual(res.status, .notFound)
        }
    }

    // MARK: - Multi-library scanning

    func testScanCoversAllConfiguredLibraries() async throws {
        try makeProjectFolder("LibA/Groupe/Dragon", name: "Dragon")
        try makeProjectFolder("LibB/Groupe/Vase", name: "Vase")

        try await app.test(.POST, "api/libraries", beforeRequest: { req in
            try req.content.encode(LibraryCreateRequest(name: "Bibliothèque A", relativePath: "LibA"))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })
        try await app.test(.POST, "api/libraries", beforeRequest: { req in
            try req.content.encode(LibraryCreateRequest(name: "Bibliothèque B", relativePath: "LibB"))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })

        try await app.test(.POST, "api/scan?wait=true") { res async throws in
            let status = try res.content.decode(ScanStatusResponse.self)
            XCTAssertEqual(status.projectCount, 2)
        }

        try await app.test(.GET, "api/projects") { res async throws in
            let projects = try res.content.decode([ProjectDTO].self)
            XCTAssertEqual(Set(projects.map(\.name)), ["Dragon", "Vase"])
        }
    }

    func testRemovingLibraryCleansUpItsProjectsOnNextScan() async throws {
        try makeProjectFolder("LibA/Groupe/Dragon", name: "Dragon")
        try makeProjectFolder("LibB/Groupe/Vase", name: "Vase")

        var libraryAID: UUID?
        try await app.test(.POST, "api/libraries", beforeRequest: { req in
            try req.content.encode(LibraryCreateRequest(name: "Bibliothèque A", relativePath: "LibA"))
        }, afterResponse: { res async throws in
            libraryAID = try res.content.decode(LibraryDTO.self).id
        })
        try await app.test(.POST, "api/libraries", beforeRequest: { req in
            try req.content.encode(LibraryCreateRequest(name: "Bibliothèque B", relativePath: "LibB"))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })
        try await app.test(.POST, "api/scan?wait=true") { res async in
            XCTAssertEqual(res.status, .ok)
        }

        try await app.test(.DELETE, "api/libraries/\(try XCTUnwrap(libraryAID))") { res async in
            XCTAssertEqual(res.status, .noContent)
        }
        try await app.test(.POST, "api/scan?wait=true") { res async throws in
            let status = try res.content.decode(ScanStatusResponse.self)
            XCTAssertEqual(status.projectCount, 1)
        }

        try await app.test(.GET, "api/projects") { res async throws in
            let projects = try res.content.decode([ProjectDTO].self)
            XCTAssertEqual(projects.map(\.name), ["Vase"])
        }
    }
}
