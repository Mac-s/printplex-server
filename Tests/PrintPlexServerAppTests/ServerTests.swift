import XCTVapor
import PrintPlexCore
@testable import PrintPlexServerApp

final class ServerTests: XCTestCase {
    var app: Application!
    var mediaDir: URL!
    var dataDir: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
        mediaDir = base.appendingPathComponent("printplex-server-media-\(UUID().uuidString)")
        dataDir = base.appendingPathComponent("printplex-server-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        // Library fixture: Groupe/Cube/{cube.3mf, info.json, rendu.png}
        let projectDir = mediaDir.appendingPathComponent("Groupe/Cube")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try TestZip.cube3MF().write(to: projectDir.appendingPathComponent("cube.3mf"))
        try Data(#"{"nom": "Cube Test", "categorie": "Tests"}"#.utf8)
            .write(to: projectDir.appendingPathComponent("info.json"))
        try Data("fake png".utf8).write(to: projectDir.appendingPathComponent("rendu.png"))

        setenv("PRINTPLEX_MEDIA_PATH", mediaDir.path, 1)
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
        try? FileManager.default.removeItem(at: mediaDir)
        try? FileManager.default.removeItem(at: dataDir)
    }

    /// Registers the whole media root as a single library — like a user
    /// picking "the whole mount" as their one library in Settings. Libraries
    /// are Plex-style: nothing is scanned until at least one is configured.
    private func addLibrary(name: String = "Bibliothèque", relativePath: String = "") async throws {
        try await app.test(.POST, "api/libraries", beforeRequest: { req in
            try req.content.encode(LibraryCreateRequest(name: name, relativePath: relativePath))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })
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
        try await addLibrary()

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

        // 4b. Manual work level persists per file (mirrors the macOS detail
        // view's per-file difficulty picker, stored in printParams)
        try await app.test(.PATCH, "api/files/\(fileID)", beforeRequest: { req in
            try req.content.encode(FileUpdateRequest(manualWorkLevel: "medium"))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let file = try res.content.decode(FileDTO.self)
            XCTAssertEqual(file.printParams?.manualWorkLevel, "medium")
        })
        try await app.test(.GET, "api/files/\(fileID)") { res async throws in
            let file = try res.content.decode(FileDTO.self)
            XCTAssertEqual(file.printParams?.manualWorkLevel, "medium")
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

        // 7. List endpoint precomputes cover image + counts for the grid view
        try await app.test(.GET, "api/projects") { res async throws in
            let project = try XCTUnwrap(try res.content.decode([ProjectDTO].self).first)
            XCTAssertEqual(project.partsCount, 1)       // cube.3mf
            XCTAssertEqual(project.totalFileCount, 3)   // + info.json + rendu.png
            XCTAssertEqual(project.imageCount, 1)       // rendu.png
            XCTAssertNotNil(project.coverFileId)
        }

        // 8. Flat file listing across the library, filterable by kind
        // (kind uses FileKind's rawValue, e.g. "threeMF" — not the file extension)
        try await app.test(.GET, "api/files?kind=threeMF") { res async throws in
            let files = try res.content.decode([FileDTO].self)
            XCTAssertEqual(files.count, 1)
            XCTAssertEqual(files.first?.fileName, "cube")
        }
        try await app.test(.GET, "api/files") { res async throws in
            let files = try res.content.decode([FileDTO].self)
            XCTAssertEqual(files.count, 3)
        }

        // 9. Aggregate kind counts for the sidebar badges
        try await app.test(.GET, "api/files/stats") { res async throws in
            let stats = try res.content.decode(FileKindCounts.self)
            XCTAssertEqual(stats.threeMF, 1)
            XCTAssertEqual(stats.other, 2) // info.json + rendu.png (kind, not role)
            XCTAssertEqual(stats.unsorted, 0)
        }
    }

    /// A 3MF with 2 plates must estimate each plate independently — never merge their
    /// geometry, and never silently only expose plate 0.
    func testMultiPlate3MFEstimatesPerPlate() async throws {
        let projectDir = mediaDir.appendingPathComponent("Groupe/MultiPlate")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try TestZip.twoPlate3MF().write(to: projectDir.appendingPathComponent("multi.3mf"))
        try Data(#"{"nom": "Multi Plate Test"}"#.utf8)
            .write(to: projectDir.appendingPathComponent("info.json"))

        try await addLibrary()
        try await app.test(.POST, "api/scan?wait=true")

        var fileID: UUID?
        try await app.test(.GET, "api/files?kind=threeMF") { res async throws in
            let files = try res.content.decode([FileDTO].self)
            let multi = try XCTUnwrap(files.first { $0.fileName == "multi" })

            let stats = try XCTUnwrap(multi.meshStats, "Le scan doit parser le plateau 0")
            XCTAssertEqual(stats.volumeMM3, 1000, accuracy: 0.001)
            XCTAssertEqual(stats.plateIndex, 0)
            XCTAssertEqual(stats.plateCount, 2)

            let plates = try XCTUnwrap(multi.plateStats, "Les stats des 2 plateaux doivent être mises en cache")
            XCTAssertEqual(plates.count, 2)
            let plate1 = try XCTUnwrap(plates.first { $0.plateIndex == 1 })
            XCTAssertEqual(plate1.volumeMM3, 8000, accuracy: 0.001)

            fileID = multi.id
        }
        let id = try XCTUnwrap(fileID)

        // Default (no plateIndex) estimates plate 0 — 10mm / 0.2mm layers = 50 layers.
        try await app.test(.GET, "api/files/\(id)/estimate") { res async throws in
            let estimate = try res.content.decode(PrintEstimate.self)
            XCTAssertEqual(estimate.layerCount, 50)
        }

        // ?plateIndex=1 estimates the 20mm cube on plate 1 — 20mm / 0.2mm layers = 100 layers.
        try await app.test(.GET, "api/files/\(id)/estimate?plateIndex=1") { res async throws in
            let estimate = try res.content.decode(PrintEstimate.self)
            XCTAssertEqual(estimate.layerCount, 100)
        }
    }

    func testPatchProjectUpdatesInfoJson() async throws {
        try await addLibrary()
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
        let infoURL = mediaDir.appendingPathComponent("Groupe/Cube/info.json")
        let dict = try JSONSerialization.jsonObject(
            with: Data(contentsOf: infoURL)) as? [String: Any]
        XCTAssertEqual(dict?["description"] as? String, "Un cube de test")
        XCTAssertEqual(dict?["tags"] as? [String], ["calibration"])
        XCTAssertEqual(dict?["categorie"] as? String, "Tests")  // preserved
    }

    /// `category`/`creator` are plain `String?` — JSON can't distinguish
    /// "omitted" from "explicitly null" there, so an empty string is the
    /// sidebar's "Supprimer" convention for clearing the field.
    func testPatchWithEmptyStringClearsCategoryAndCreator() async throws {
        try await addLibrary()
        try await app.test(.POST, "api/scan?wait=true")
        var projectID: UUID?
        try await app.test(.GET, "api/projects") { res async throws in
            let project = try res.content.decode([ProjectDTO].self).first
            projectID = project?.id
            XCTAssertEqual(project?.category, "Tests")
        }
        let id = try XCTUnwrap(projectID)

        try await app.test(.PATCH, "api/projects/\(id)", beforeRequest: { req in
            try req.content.encode(ProjectUpdateRequest(category: "", creator: ""))
        }, afterResponse: { res async throws in
            let project = try res.content.decode(ProjectDTO.self)
            XCTAssertNil(project.category)
            XCTAssertNil(project.creator)
        })

        let infoURL = mediaDir.appendingPathComponent("Groupe/Cube/info.json")
        let dict = try JSONSerialization.jsonObject(
            with: Data(contentsOf: infoURL)) as? [String: Any]
        XCTAssertNil(dict?["categorie"])
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
