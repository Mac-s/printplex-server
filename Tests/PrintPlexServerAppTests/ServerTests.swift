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

    /// A stale browser-cached API response is exactly how a real deploy once
    /// silently kept serving an old product shape (missing fields added
    /// later) even though the server had long since started returning them —
    /// every `/api/*` response must tell the browser never to reuse it.
    func testAPIResponsesAreNeverCached() async throws {
        try await app.test(.GET, "api/projects") { res async in
            XCTAssertEqual(res.headers.cacheControl?.noStore, true)
        }
        // The static dashboard itself is unaffected — it's fine (expected) for
        // browsers to cache Public/ assets.
        try await app.test(.GET, "health") { res async in
            XCTAssertNil(res.headers.cacheControl)
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

        // 4b-bis. Real/measured print data (from the "Impression réelle" block)
        // persists alongside manualWorkLevel in the same printParams blob,
        // without clobbering it.
        try await app.test(.PATCH, "api/files/\(fileID)", beforeRequest: { req in
            try req.content.encode(FileUpdateRequest(actualPrintTimeSec: 9000, actualFilamentGrams: 187.5))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let file = try res.content.decode(FileDTO.self)
            XCTAssertEqual(file.printParams?.actualPrintTimeSec, 9000)
            XCTAssertEqual(file.printParams?.actualFilamentGrams, 187.5)
            XCTAssertEqual(file.printParams?.manualWorkLevel, "medium", "unrelated field untouched")
        })

        // 4b-ter. hasManualEstimate flips true once real print data exists on
        // any file — backs the "Estimé manuellement" sidebar filter, and is
        // precomputed on both the list and detail endpoints.
        try await app.test(.GET, "api/projects/\(id)") { res async throws in
            let project = try res.content.decode(ProjectDTO.self)
            XCTAssertTrue(project.hasManualEstimate)
        }
        try await app.test(.GET, "api/projects") { res async throws in
            let projects = try res.content.decode([ProjectDTO].self)
            XCTAssertEqual(projects.first { $0.id == id }?.hasManualEstimate, true)
        }

        // 4c. "Already printed" is a manual flag, persisted like other metadata
        // (DB + info.json), and readable from both list and detail endpoints.
        try await app.test(.PATCH, "api/projects/\(id)", beforeRequest: { req in
            try req.content.encode(ProjectUpdateRequest(alreadyPrinted: true))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let project = try res.content.decode(ProjectDTO.self)
            XCTAssertEqual(project.alreadyPrinted, true)
        })
        try await app.test(.GET, "api/projects") { res async throws in
            let project = try XCTUnwrap(try res.content.decode([ProjectDTO].self).first)
            XCTAssertEqual(project.alreadyPrinted, true)
        }
        let infoURL = mediaDir.appendingPathComponent("Groupe/Cube/info.json")
        let infoDict = try JSONSerialization.jsonObject(
            with: Data(contentsOf: infoURL)) as? [String: Any]
        XCTAssertEqual(infoDict?["deja_imprime"] as? Bool, true)

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

    /// Same class of bug as `already_printed` before it: the DB write alone
    /// isn't enough — `LibraryScanner.updateProjectInfo`'s merge dictionary
    /// has to know about a field too, or it silently never reaches info.json
    /// even though the API response looks correct.
    func testPatchPersistsSourceInfoToInfoJson() async throws {
        try await addLibrary()
        try await app.test(.POST, "api/scan?wait=true")

        var projectID: UUID?
        try await app.test(.GET, "api/projects") { res async throws in
            projectID = try res.content.decode([ProjectDTO].self).first?.id
        }
        let id = try XCTUnwrap(projectID)

        try await app.test(.PATCH, "api/projects/\(id)", beforeRequest: { req in
            try req.content.encode(ProjectUpdateRequest(
                sourceUrl: "https://prinnit.com/ForgeCore/design/abc123",
                sourceHardware: ["N52 Magnet (6 x 2mm) × 8"],
                sourceEstimatedWeight: "1.16kg",
                sourceEstimatedPrintTime: "2d 5h 44m",
                sourceInstructionImages: ["forgecore-instructions-1.webp"]
            ))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let project = try res.content.decode(ProjectDTO.self)
            XCTAssertEqual(project.sourceUrl, "https://prinnit.com/ForgeCore/design/abc123")
            XCTAssertEqual(project.sourceHardware, ["N52 Magnet (6 x 2mm) × 8"])
            XCTAssertEqual(project.sourceEstimatedWeight, "1.16kg")
            XCTAssertEqual(project.sourceEstimatedPrintTime, "2d 5h 44m")
            XCTAssertEqual(project.sourceInstructionImages, ["forgecore-instructions-1.webp"])
        })

        let infoURL = mediaDir.appendingPathComponent("Groupe/Cube/info.json")
        let dict = try JSONSerialization.jsonObject(
            with: Data(contentsOf: infoURL)) as? [String: Any]
        XCTAssertEqual(dict?["source_url"] as? String, "https://prinnit.com/ForgeCore/design/abc123")
        XCTAssertEqual(dict?["source_hardware"] as? [String], ["N52 Magnet (6 x 2mm) × 8"])
        XCTAssertEqual(dict?["source_estimated_weight"] as? String, "1.16kg")
        XCTAssertEqual(dict?["source_estimated_print_time"] as? String, "2d 5h 44m")
        XCTAssertEqual(dict?["source_instruction_images"] as? [String], ["forgecore-instructions-1.webp"])
    }

    /// Imported assembly-instruction images are plain `renderImage`-role
    /// files on disk like any product photo — without this exclusion, one
    /// could get auto-picked as the project's cover image, or inflate the
    /// "N photos" count shown on its grid card.
    func testInstructionImagesExcludedFromCoverAndImageCount() async throws {
        try await addLibrary()

        let projectDir = mediaDir.appendingPathComponent("Groupe/CasqueTest")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try Data("fake png".utf8).write(to: projectDir.appendingPathComponent("photo-produit.png"))
        try Data("fake instructions".utf8).write(to: projectDir.appendingPathComponent("forgecore-instructions-1.png"))
        try Data(#"{"nom": "Casque Test"}"#.utf8).write(to: projectDir.appendingPathComponent("info.json"))

        try await app.test(.POST, "api/scan?wait=true")

        var project: ProjectDTO?
        try await app.test(.GET, "api/projects") { res async throws in
            project = try res.content.decode([ProjectDTO].self).first { $0.name == "Casque Test" }
        }
        let id = try XCTUnwrap(project?.id)

        try await app.test(.PATCH, "api/projects/\(id)", beforeRequest: { req in
            try req.content.encode(ProjectUpdateRequest(sourceInstructionImages: ["forgecore-instructions-1.png"]))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })

        try await app.test(.GET, "api/projects") { res async throws in
            let updated = try XCTUnwrap(try res.content.decode([ProjectDTO].self).first { $0.name == "Casque Test" })
            // Only the real product photo counts — the instructions image is excluded.
            XCTAssertEqual(updated.imageCount, 1)
            let cover = try await FileModel.find(updated.coverFileId, on: app.db)
            XCTAssertEqual(cover?.fileName, "photo-produit")
        }
    }

    /// `import.js` (and the ForgeCore relay) organize imported photos into
    /// gallery/users-gallery/instructions subfolders, recording
    /// `source_instruction_images` as paths relative to the project folder
    /// (e.g. "instructions/foo.png") rather than bare filenames — the
    /// exclusion above must still work against that form, not just the
    /// older flat-file convention.
    func testInstructionImagesExcludedWhenStoredAsSubfolderPaths() async throws {
        try await addLibrary()

        let projectDir = mediaDir.appendingPathComponent("Groupe/SubfolderTest")
        let instructionsDir = projectDir.appendingPathComponent("instructions")
        try FileManager.default.createDirectory(at: instructionsDir, withIntermediateDirectories: true)
        try Data("fake png".utf8).write(to: projectDir.appendingPathComponent("photo-produit.png"))
        try Data("fake instructions".utf8).write(to: instructionsDir.appendingPathComponent("forgecore-instructions-1.png"))
        try Data(#"{"nom": "Subfolder Test"}"#.utf8).write(to: projectDir.appendingPathComponent("info.json"))

        try await app.test(.POST, "api/scan?wait=true")

        var project: ProjectDTO?
        try await app.test(.GET, "api/projects") { res async throws in
            project = try res.content.decode([ProjectDTO].self).first { $0.name == "Subfolder Test" }
        }
        let id = try XCTUnwrap(project?.id)

        try await app.test(.PATCH, "api/projects/\(id)", beforeRequest: { req in
            try req.content.encode(ProjectUpdateRequest(sourceInstructionImages: ["instructions/forgecore-instructions-1.png"]))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })

        try await app.test(.GET, "api/projects") { res async throws in
            let updated = try XCTUnwrap(try res.content.decode([ProjectDTO].self).first { $0.name == "Subfolder Test" })
            XCTAssertEqual(updated.imageCount, 1)
            let cover = try await FileModel.find(updated.coverFileId, on: app.db)
            XCTAssertEqual(cover?.fileName, "photo-produit")
        }
    }

    /// The project detail view's main gallery needs full resolution — this
    /// endpoint must stream the source bytes untouched, never through the
    /// vips resize path used by `/thumbnail`.
    func testOriginalEndpointServesExactSourceBytes() async throws {
        try await addLibrary()
        let projectDir = mediaDir.appendingPathComponent("Groupe/PhotoTest")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let sourceBytes = Data("not actually a png but that's fine for this test".utf8)
        try sourceBytes.write(to: projectDir.appendingPathComponent("photo.png"))
        try Data(#"{"nom": "Photo Test"}"#.utf8).write(to: projectDir.appendingPathComponent("info.json"))
        try await app.test(.POST, "api/scan?wait=true")

        var project: ProjectDTO?
        try await app.test(.GET, "api/projects") { res async throws in
            project = try res.content.decode([ProjectDTO].self).first { $0.name == "Photo Test" }
        }
        let id = try XCTUnwrap(project?.id)
        var fileId: UUID?
        try await app.test(.GET, "api/projects/\(id)") { res async throws in
            let detail = try res.content.decode(ProjectDTO.self)
            fileId = try XCTUnwrap(detail.files).first { $0.fileName == "photo" }?.id
        }
        let imageId = try XCTUnwrap(fileId)

        try await app.test(.GET, "api/files/\(imageId)/original", afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, String(data: sourceBytes, encoding: .utf8))
        })
    }

    /// Non-image files (a 3D model part here) have no "original photo" to
    /// serve — `/original` is scoped to `renderImage` files only.
    func testOriginalEndpointRejectsNonImageFiles() async throws {
        try await addLibrary()
        let projectDir = mediaDir.appendingPathComponent("Groupe/ModelOnly")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try Data("fake stl".utf8).write(to: projectDir.appendingPathComponent("part.stl"))
        try await app.test(.POST, "api/scan?wait=true")

        var project: ProjectDTO?
        try await app.test(.GET, "api/projects") { res async throws in
            project = try res.content.decode([ProjectDTO].self).first { $0.name == "ModelOnly" }
        }
        let id = try XCTUnwrap(project?.id)
        var fileId: UUID?
        try await app.test(.GET, "api/projects/\(id)") { res async throws in
            let detail = try res.content.decode(ProjectDTO.self)
            fileId = try XCTUnwrap(detail.files).first { $0.fileName == "part" }?.id
        }
        let modelId = try XCTUnwrap(fileId)

        try await app.test(.GET, "api/files/\(modelId)/original", afterResponse: { res async in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    /// Whether or not `vipsthumbnail` is installed on the machine running
    /// this test, `/thumbnail` must still return the image successfully —
    /// falling back to the original file if the resize tool is unavailable.
    func testThumbnailForRenderImageAlwaysSucceeds() async throws {
        try await addLibrary()
        let projectDir = mediaDir.appendingPathComponent("Groupe/ThumbTest")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try Data("fake png bytes".utf8).write(to: projectDir.appendingPathComponent("photo.png"))
        try Data(#"{"nom": "ThumbTest"}"#.utf8).write(to: projectDir.appendingPathComponent("info.json"))
        try await app.test(.POST, "api/scan?wait=true")

        var project: ProjectDTO?
        try await app.test(.GET, "api/projects") { res async throws in
            project = try res.content.decode([ProjectDTO].self).first { $0.name == "ThumbTest" }
        }
        let id = try XCTUnwrap(project?.id)
        var fileId: UUID?
        try await app.test(.GET, "api/projects/\(id)") { res async throws in
            let detail = try res.content.decode(ProjectDTO.self)
            fileId = try XCTUnwrap(detail.files).first { $0.fileName == "photo" }?.id
        }
        let imageId = try XCTUnwrap(fileId)

        try await app.test(.GET, "api/files/\(imageId)/thumbnail", afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertGreaterThan(res.body.readableBytes, 0)
        })
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

    /// The container never knows its own bind-mount source — `localFolderPath`
    /// only appears once the user tells the dashboard via Réglages, and is
    /// `folderPath` with the container's media root swapped for that value.
    func testLocalFolderPathReflectsConfiguredLocalMediaPath() async throws {
        try await addLibrary()
        try await app.test(.POST, "api/scan?wait=true")

        // Nothing configured yet — absent on both list and detail.
        var projectID: UUID?
        try await app.test(.GET, "api/projects") { res async throws in
            let project = try res.content.decode([ProjectDTO].self).first
            projectID = project?.id
            XCTAssertNil(project?.localFolderPath)
        }
        let id = try XCTUnwrap(projectID)
        try await app.test(.GET, "api/projects/\(id)") { res async throws in
            let project = try res.content.decode(ProjectDTO.self)
            XCTAssertNil(project.localFolderPath)
        }

        try await app.test(.PATCH, "api/settings/local-path", beforeRequest: { req in
            try req.content.encode(LocalPathSettingsUpdateRequest(localMediaPath: "/Volumes/NAS/PrintPlex"))
        }, afterResponse: { res async in XCTAssertEqual(res.status, .ok) })

        let expected = "/Volumes/NAS/PrintPlex/Groupe/Cube"
        try await app.test(.GET, "api/projects") { res async throws in
            let project = try res.content.decode([ProjectDTO].self).first
            XCTAssertEqual(project?.localFolderPath, expected)
        }
        try await app.test(.GET, "api/projects/\(id)") { res async throws in
            let project = try res.content.decode(ProjectDTO.self)
            XCTAssertEqual(project.localFolderPath, expected)
        }
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

    func testCreateProductRejectsEmptyTitle() async throws {
        // Checked before touching Shopify at all, so this doesn't need credentials.
        try await app.test(.POST, "api/shopify/products", beforeRequest: { req in
            try req.content.encode(ShopifyCreateProductRequest(title: "   "))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testCreateProductUnconfiguredReturns503() async throws {
        try await app.test(.POST, "api/shopify/products", beforeRequest: { req in
            try req.content.encode(ShopifyCreateProductRequest(title: "Casque Power Ranger Bleu"))
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .serviceUnavailable)
        })
    }

    // MARK: - ForgeCore relay

    /// Only projects the dashboard has actually marked "pending" (via the
    /// regular PATCH endpoint, same as the manual source-URL field) should
    /// show up for the relay to pick up.
    func testForgeCorePendingListsOnlyProjectsAwaitingScrape() async throws {
        try await addLibrary()
        let dirA = mediaDir.appendingPathComponent("Groupe/PendingOne")
        let dirB = mediaDir.appendingPathComponent("Groupe/NotPending")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try Data(#"{"nom": "PendingOne"}"#.utf8).write(to: dirA.appendingPathComponent("info.json"))
        try Data(#"{"nom": "NotPending"}"#.utf8).write(to: dirB.appendingPathComponent("info.json"))
        try await app.test(.POST, "api/scan?wait=true")

        var pendingId: UUID?
        try await app.test(.GET, "api/projects") { res async throws in
            pendingId = try res.content.decode([ProjectDTO].self).first { $0.name == "PendingOne" }?.id
        }
        let id = try XCTUnwrap(pendingId)

        try await app.test(.PATCH, "api/projects/\(id)", beforeRequest: { req in
            try req.content.encode(ProjectUpdateRequest(
                sourceUrl: "https://prinnit.com/ForgeCore/design/x", sourceScrapeStatus: "pending"))
        }, afterResponse: { res async in XCTAssertEqual(res.status, .ok) })

        try await app.test(.GET, "api/forgecore/pending") { res async throws in
            XCTAssertEqual(res.status, .ok)
            let pending = try res.content.decode([ForgeCorePendingProject].self)
            XCTAssertEqual(pending.count, 1)
            XCTAssertEqual(pending.first?.id, id)
            XCTAssertEqual(pending.first?.sourceUrl, "https://prinnit.com/ForgeCore/design/x")
        }
    }

    /// End-to-end happy path: the relay posts scraped metadata + photos,
    /// which should land on disk, in the DB, in info.json, and clear the
    /// pending status — with the instruction photo still excluded from the
    /// gallery/cover the same way a manual import via import.js would be.
    func testForgeCoreImportResultWritesPhotosAndClearsPendingStatus() async throws {
        try await addLibrary()
        let projectDir = mediaDir.appendingPathComponent("Groupe/RelayTest")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try Data(#"{"nom": "RelayTest"}"#.utf8).write(to: projectDir.appendingPathComponent("info.json"))
        try await app.test(.POST, "api/scan?wait=true")

        var projectID: UUID?
        try await app.test(.GET, "api/projects") { res async throws in
            projectID = try res.content.decode([ProjectDTO].self).first { $0.name == "RelayTest" }?.id
        }
        let id = try XCTUnwrap(projectID)

        try await app.test(.PATCH, "api/projects/\(id)", beforeRequest: { req in
            try req.content.encode(ProjectUpdateRequest(
                sourceUrl: "https://prinnit.com/ForgeCore/design/y", sourceScrapeStatus: "pending"))
        }, afterResponse: { res async in XCTAssertEqual(res.status, .ok) })

        let galleryBytes = Data("fake gallery photo".utf8)
        let communityBytes = Data("fake community photo".utf8)
        let instructionBytes = Data("fake instructions photo".utf8)
        let result = ForgeCoreImportResultRequest(
            success: true,
            description: "Une belle description",
            sourceHardware: ["N52 Magnet (6 x 2mm) × 8"],
            sourceEstimatedWeight: "1.16kg",
            sourceEstimatedPrintTime: "2d 5h 44m",
            galleryPhotos: [ForgeCorePhotoPayload(filename: "forgecore-gallery-1.webp", dataBase64: galleryBytes.base64EncodedString())],
            communityPhotos: [ForgeCorePhotoPayload(filename: "forgecore-communaute-1.webp", dataBase64: communityBytes.base64EncodedString())],
            instructionPhotos: [ForgeCorePhotoPayload(filename: "forgecore-instructions-1.webp", dataBase64: instructionBytes.base64EncodedString())]
        )
        try await app.test(.POST, "api/projects/\(id)/forgecore-import-result", beforeRequest: { req in
            try req.content.encode(result)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let project = try res.content.decode(ProjectDTO.self)
            XCTAssertEqual(project.sourceHardware, ["N52 Magnet (6 x 2mm) × 8"])
            XCTAssertEqual(project.sourceEstimatedWeight, "1.16kg")
            XCTAssertEqual(project.sourceEstimatedPrintTime, "2d 5h 44m")
            XCTAssertEqual(project.sourceInstructionImages, ["instructions/forgecore-instructions-1.webp"])
            XCTAssertEqual(project.projectDescription, "Une belle description")
            XCTAssertNil(project.sourceScrapeStatus)
            // Gallery + community photos count; the instruction photo is excluded.
            XCTAssertEqual(project.imageCount, 2)
        })

        XCTAssertEqual(try Data(contentsOf: projectDir.appendingPathComponent("gallery/forgecore-gallery-1.webp")), galleryBytes)
        XCTAssertEqual(try Data(contentsOf: projectDir.appendingPathComponent("users-gallery/forgecore-communaute-1.webp")), communityBytes)
        XCTAssertEqual(try Data(contentsOf: projectDir.appendingPathComponent("instructions/forgecore-instructions-1.webp")), instructionBytes)

        try await app.test(.GET, "api/forgecore/pending") { res async throws in
            let pending = try res.content.decode([ForgeCorePendingProject].self)
            XCTAssertTrue(pending.isEmpty)
        }

        let infoDict = try JSONSerialization.jsonObject(
            with: Data(contentsOf: projectDir.appendingPathComponent("info.json"))) as? [String: Any]
        XCTAssertEqual(infoDict?["source_hardware"] as? [String], ["N52 Magnet (6 x 2mm) × 8"])
    }

    /// A failed scrape (session expired, page layout changed, network error…)
    /// should surface as a readable error on the project, not silently vanish.
    func testForgeCoreImportResultFailureRecordsError() async throws {
        try await addLibrary()
        let projectDir = mediaDir.appendingPathComponent("Groupe/RelayFail")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try Data(#"{"nom": "RelayFail"}"#.utf8).write(to: projectDir.appendingPathComponent("info.json"))
        try await app.test(.POST, "api/scan?wait=true")

        var projectID: UUID?
        try await app.test(.GET, "api/projects") { res async throws in
            projectID = try res.content.decode([ProjectDTO].self).first { $0.name == "RelayFail" }?.id
        }
        let id = try XCTUnwrap(projectID)

        try await app.test(.PATCH, "api/projects/\(id)", beforeRequest: { req in
            try req.content.encode(ProjectUpdateRequest(
                sourceUrl: "https://prinnit.com/ForgeCore/design/z", sourceScrapeStatus: "pending"))
        }, afterResponse: { res async in XCTAssertEqual(res.status, .ok) })

        let result = ForgeCoreImportResultRequest(success: false, error: "Session ForgeCore expirée")
        try await app.test(.POST, "api/projects/\(id)/forgecore-import-result", beforeRequest: { req in
            try req.content.encode(result)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let project = try res.content.decode(ProjectDTO.self)
            XCTAssertEqual(project.sourceScrapeStatus, "failed")
            XCTAssertEqual(project.sourceScrapeError, "Session ForgeCore expirée")
        })
    }
}
