import XCTVapor
import PrintPlexCore
@testable import PrintPlexServerApp

final class ServerTests: XCTestCase {
    var app: Application!
    var libraryDir: URL!
    var dataDir: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
        libraryDir = base.appendingPathComponent("printplex-server-lib-\(UUID().uuidString)")
        dataDir = base.appendingPathComponent("printplex-server-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)

        // Library fixture: Groupe/Cube/{cube.3mf, info.json, rendu.png}
        let projectDir = libraryDir.appendingPathComponent("Groupe/Cube")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try TestZip.cube3MF().write(to: projectDir.appendingPathComponent("cube.3mf"))
        try Data(#"{"nom": "Cube Test", "categorie": "Tests"}"#.utf8)
            .write(to: projectDir.appendingPathComponent("info.json"))
        try Data("fake png".utf8).write(to: projectDir.appendingPathComponent("rendu.png"))

        setenv("PRINTPLEX_LIBRARY_PATH", libraryDir.path, 1)
        setenv("PRINTPLEX_DATA_PATH", dataDir.path, 1)
        setenv("PRINTPLEX_DB_IN_MEMORY", "1", 1)
        setenv("PRINTPLEX_SCAN_INTERVAL_MIN", "0", 1)
        // Make sure ambient Shopify credentials never leak into the tests
        setenv("SHOPIFY_STORE_DOMAIN", "", 1)
        setenv("SHOPIFY_ACCESS_TOKEN", "", 1)

        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dataDir)
    }

    // MARK: - Tests

    func testHealth() async throws {
        try await app.test(.GET, "health") { res async in
            XCTAssertEqual(res.status, .ok)
        }
    }

    func testPrintersAndMaterials() async throws {
        try await app.test(.GET, "api/printers") { res async throws in
            XCTAssertEqual(res.status, .ok)
            let printers = try res.content.decode([PrinterProfile].self)
            XCTAssertEqual(printers.count, 3)
        }
        try await app.test(.GET, "api/materials") { res async throws in
            let materials = try res.content.decode([PrintMaterial].self)
            XCTAssertEqual(materials.first?.name, "PLA")
        }
    }

    func testFullScanFlow() async throws {
        // 1. Scan (synchronous — includes the mesh parsing pass)
        try await app.test(.POST, "api/scan?wait=true") { res async throws in
            XCTAssertEqual(res.status, .ok)
            let status = try res.content.decode(ScanStatusResponse.self)
            XCTAssertFalse(status.isScanning)
            XCTAssertEqual(status.projectCount, 1)
        }

        // 2. Project list
        var projectID: UUID?
        try await app.test(.GET, "api/projects") { res async throws in
            XCTAssertEqual(res.status, .ok)
            let projects = try res.content.decode([ProjectDTO].self)
            XCTAssertEqual(projects.count, 1)
            XCTAssertEqual(projects.first?.name, "Cube Test")
            XCTAssertEqual(projects.first?.category, "Tests")
            projectID = projects.first?.id
        }
        let id = try XCTUnwrap(projectID)

        // 3. Detail contains the files, and the 3MF got its mesh stats parsed
        var cubeFileID: UUID?
        try await app.test(.GET, "api/projects/\(id)") { res async throws in
            let project = try res.content.decode(ProjectDTO.self)
            let files = try XCTUnwrap(project.files)
            XCTAssertEqual(files.count, 3)  // cube.3mf + info.json + rendu.png
            let cube = try XCTUnwrap(files.first { $0.fileExtension == "3mf" })
            let stats = try XCTUnwrap(cube.meshStats, "Le scan doit parser le maillage du .3mf")
            XCTAssertEqual(stats.volumeMM3, 1000, accuracy: 0.001)
            cubeFileID = cube.id
        }
        let fileID = try XCTUnwrap(cubeFileID)

        // 4. Estimate for the cube: 10 mm tall / 0.2 mm layers = 50 layers
        try await app.test(.GET, "api/files/\(fileID)/estimate") { res async throws in
            XCTAssertEqual(res.status, .ok)
            let estimate = try res.content.decode(PrintEstimate.self)
            XCTAssertEqual(estimate.layerCount, 50)
            XCTAssertTrue(estimate.fitsOnBed)
        }

        // 5. Project-level estimate aggregates the parts
        try await app.test(.GET, "api/projects/\(id)/estimate?manualWork=easy") { res async throws in
            let estimate = try res.content.decode(PrintEstimate.self)
            XCTAssertEqual(estimate.manualCostEur, 5.0)
        }

        // 6. Download round-trips the file
        try await app.test(.GET, "api/files/\(fileID)/download") { res async in
            XCTAssertEqual(res.status, .ok)
        }
    }

    func testPatchProjectUpdatesInfoJson() async throws {
        try await app.test(.POST, "api/scan?wait=true")

        var projectID: UUID?
        try await app.test(.GET, "api/projects") { res async throws in
            projectID = try res.content.decode([ProjectDTO].self).first?.id
        }
        let id = try XCTUnwrap(projectID)

        try await app.test(.PATCH, "api/projects/\(id)", beforeRequest: { req in
            try req.content.encode(ProjectUpdateRequest(
                projectDescription: "Un cube de test",
                tags: ["calibration"]
            ))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let project = try res.content.decode(ProjectDTO.self)
            XCTAssertEqual(project.projectDescription, "Un cube de test")
            XCTAssertEqual(project.tags, ["calibration"])
        })

        // The folder's info.json is updated too (library = source of truth)
        let infoURL = libraryDir.appendingPathComponent("Groupe/Cube/info.json")
        let dict = try JSONSerialization.jsonObject(
            with: Data(contentsOf: infoURL)) as? [String: Any]
        XCTAssertEqual(dict?["description"] as? String, "Un cube de test")
        XCTAssertEqual(dict?["tags"] as? [String], ["calibration"])
        XCTAssertEqual(dict?["categorie"] as? String, "Tests")  // preserved
    }

    func testScanStatusEndpoint() async throws {
        try await app.test(.GET, "api/scan/status") { res async throws in
            XCTAssertEqual(res.status, .ok)
            let status = try res.content.decode(ScanStatusResponse.self)
            XCTAssertFalse(status.isScanning)
            XCTAssertNil(status.lastScanDate)
        }
    }

    func testShopifyUnconfiguredReturns503() async throws {
        try await app.test(.GET, "api/shopify/products") { res async in
            XCTAssertEqual(res.status, .serviceUnavailable)
        }
    }
}
