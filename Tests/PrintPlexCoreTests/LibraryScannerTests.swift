import XCTest
@testable import PrintPlexCore

final class LibraryScannerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("printplex-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relativePath: String, _ content: String = "x") throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    private func collectEvents() async -> [ScanEvent] {
        var events: [ScanEvent] = []
        for await event in LibraryScanner.scan(root: root) {
            events.append(event)
        }
        return events
    }

    // MARK: - Project detection

    func testDetectsProjectFromModelFileDepth() async throws {
        try write("Figurines/Dragon/dragon.stl")
        try write("Figurines/Dragon/rendu.png")
        try write("orphelin.stl")

        let events = await collectEvents()

        let projects = events.compactMap { event -> ScannedProject? in
            if case .projectDiscovered(let p, _) = event { return p }
            return nil
        }
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.name, "Dragon")

        // The render image must be attached to the Dragon project
        let projectFiles = events.compactMap { event -> String? in
            if case .fileScanned(let f, _, _, _) = event { return f.fileName }
            return nil
        }
        XCTAssertTrue(projectFiles.contains("dragon"))
        XCTAssertTrue(projectFiles.contains("rendu"))

        // Root-level file is an orphan
        let orphans = events.compactMap { event -> String? in
            if case .unsortedFileScanned(let f, _, _) = event { return f.fileName }
            return nil
        }
        XCTAssertEqual(orphans, ["orphelin"])
    }

    func testIgnoresNASHousekeepingFolders() async throws {
        try write("Figurines/Dragon/dragon.stl")
        // Synology (and similar NAS) create these throughout the tree, at every
        // level, on every network share — never real user content.
        try write("Figurines/Dragon/@eaDir/SYNOINDEX_THUMB.jpg")
        try write("Figurines/@SynoResource/somefile.dat")
        try write("Figurines/#recycle/deleted.stl")
        try write("@eaDir/root_level_thumb.jpg")
        try write("orphelin.stl")

        let events = await collectEvents()

        let allFileNames = events.compactMap { event -> String? in
            switch event {
            case .fileScanned(let f, _, _, _): return f.fileName
            case .unsortedFileScanned(let f, _, _): return f.fileName
            default: return nil
            }
        }
        XCTAssertFalse(allFileNames.contains("SYNOINDEX_THUMB"))
        XCTAssertFalse(allFileNames.contains("somefile"))
        XCTAssertFalse(allFileNames.contains("deleted"))
        XCTAssertFalse(allFileNames.contains("root_level_thumb"))
        XCTAssertTrue(allFileNames.contains("dragon"))
        XCTAssertTrue(allFileNames.contains("orphelin"))
    }

    func testIgnoresSynoEAStreamSidecarFiles() async throws {
        try write("Figurines/Dragon/dragon.stl")
        try write("Figurines/Dragon/rendu.png")
        // Synology stores a file's extended attributes (Finder metadata, resource
        // forks…) as a *separate* sidecar file when served over NFS/SMB, since
        // those protocols can't carry them inline — never real content, and
        // named after the original file rather than being its own clean name,
        // so it can't be matched as an exact ignored folder name.
        try write("Figurines/Dragon/dragon.stl@SynoEAStream")
        try write("Figurines/Dragon/rendu.png@SYNOEASTREAM") // casing shouldn't matter

        let events = await collectEvents()

        let scannedFileCount = events.reduce(0) { count, event in
            if case .fileScanned = event { return count + 1 }
            return count
        }
        XCTAssertEqual(scannedFileCount, 2, "only dragon.stl and rendu.png, not their @SynoEAStream sidecars")
    }

    func testSkipsDateGroupingFolders() async throws {
        try write("Posters/2026-04/MonProjet/piece.3mf")

        let events = await collectEvents()

        let projects = events.compactMap { event -> ScannedProject? in
            if case .projectDiscovered(let p, _) = event { return p }
            return nil
        }
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.name, "MonProjet")
    }

    func testInfoJsonMarksProjectAndProvidesName() async throws {
        try write("Groupe/AvecInfo/info.json", #"{"nom": "Nom Personnalisé"}"#)
        try write("Groupe/AvecInfo/rendu.png")

        let events = await collectEvents()

        let projects = events.compactMap { event -> ScannedProject? in
            if case .projectDiscovered(let p, _) = event { return p }
            return nil
        }
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.name, "Nom Personnalisé")
        XCTAssertEqual(projects.first?.info?.nom, "Nom Personnalisé")
    }

    func testKnownPathsFlagAsNotNew() async throws {
        try write("Groupe/Projet/piece.stl")
        let projectPath = root.appendingPathComponent("Groupe/Projet").standardizedFileURL.path
        let filePath = root.appendingPathComponent("Groupe/Projet/piece.stl")
            .standardizedFileURL.path

        var isNewProject: Bool?
        var isNewFile: Bool?
        for await event in LibraryScanner.scan(
            root: root,
            knownProjectPaths: [projectPath],
            knownFilePaths: [filePath]
        ) {
            if case .projectDiscovered(_, let isNew) = event { isNewProject = isNew }
            if case .fileScanned(_, _, let isNew, _) = event { isNewFile = isNew }
        }

        XCTAssertEqual(isNewProject, false)
        XCTAssertEqual(isNewFile, false)
    }

    // MARK: - Date grouping folder heuristics

    func testDateGroupingFolderDetection() {
        XCTAssertTrue(LibraryScanner.isDateGroupingFolder("2026-04"))
        XCTAssertTrue(LibraryScanner.isDateGroupingFolder("2026-04-15"))
        XCTAssertTrue(LibraryScanner.isDateGroupingFolder("Apr 2026"))
        XCTAssertTrue(LibraryScanner.isDateGroupingFolder("Juin 2026"))
        XCTAssertTrue(LibraryScanner.isDateGroupingFolder("Décembre 2026"))
        XCTAssertFalse(LibraryScanner.isDateGroupingFolder("MonProjet"))
        XCTAssertFalse(LibraryScanner.isDateGroupingFolder("Dragon 3D"))
    }

    // MARK: - info.json round-trip

    func testUpdateProjectInfoPreservesUnknownKeys() throws {
        let projectDir = root.appendingPathComponent("Groupe/Projet")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let infoURL = projectDir.appendingPathComponent("info.json")
        try Data(#"{"nom": "Ancien", "champ_inconnu": 42}"#.utf8).write(to: infoURL)

        try LibraryScanner.updateProjectInfo(in: projectDir.path) { info in
            info.nom = "Nouveau"
            info.tags = ["deco"]
        }

        let dict = try JSONSerialization.jsonObject(
            with: Data(contentsOf: infoURL)) as? [String: Any]
        XCTAssertEqual(dict?["nom"] as? String, "Nouveau")
        XCTAssertEqual(dict?["champ_inconnu"] as? Int, 42)
        XCTAssertEqual(dict?["tags"] as? [String], ["deco"])
    }

    /// Setting a known field back to nil must actually clear it on disk.
    /// JSONEncoder's default Optional handling omits nil properties instead
    /// of encoding `null`, which would make the merge silently keep stale
    /// values — this pins the manual-dictionary fix in place.
    func testUpdateProjectInfoClearsFieldSetToNil() throws {
        let projectDir = root.appendingPathComponent("Groupe/Projet")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let infoURL = projectDir.appendingPathComponent("info.json")
        try Data(#"{"categorie": "Figurines", "createur": "Max"}"#.utf8).write(to: infoURL)

        try LibraryScanner.updateProjectInfo(in: projectDir.path) { info in
            info.categorie = nil
        }

        let dict = try JSONSerialization.jsonObject(
            with: Data(contentsOf: infoURL)) as? [String: Any]
        XCTAssertNil(dict?["categorie"])
        XCTAssertEqual(dict?["createur"] as? String, "Max") // untouched field survives
    }

    // MARK: - info.json generation

    func testGenerateProjectInfoDetectsMaterialsAndTags() {
        let info = LibraryScanner.generateProjectInfo(
            folderName: "Dragon PETG",
            fileNames: ["corps-pla.stl", "ailes.stl"],
            existingCategories: ["Figurines", "Déco"],
            existingMaterials: [],
            existingTags: ["dragon", "fantasy"]
        )
        XCTAssertEqual(info.nom, "Dragon PETG")
        XCTAssertEqual(info.materiaux_suggeres, ["PLA", "PETG"])
        XCTAssertEqual(info.tags, ["dragon"])
    }

    // MARK: - File role / kind

    func testFileRoleMapping() {
        XCTAssertEqual(FileRole.from(extension: "stl"), .modelPart)
        XCTAssertEqual(FileRole.from(extension: "3mf"), .modelPart)
        XCTAssertEqual(FileRole.from(extension: "png"), .renderImage)
        XCTAssertEqual(FileRole.from(extension: "pdf"), .document)
        XCTAssertEqual(FileRole.from(extension: "gcode"), .slicerConfig)
        XCTAssertEqual(FileRole.from(extension: "json", fileName: "info"), .document)
        XCTAssertEqual(FileRole.from(extension: "json", fileName: "config"), .slicerConfig)
        XCTAssertEqual(FileRole.from(extension: "blend"), .other)
    }

    func testFileKindMapping() {
        XCTAssertEqual(FileKind.from(extension: "stl"), .stl)
        XCTAssertEqual(FileKind.from(extension: "3MF"), .threeMF)
        XCTAssertEqual(FileKind.from(extension: "step"), .step)
        XCTAssertEqual(FileKind.from(extension: "stp"), .step)
        XCTAssertEqual(FileKind.from(extension: "txt"), .other)
    }

    // MARK: - Hashing

    func testHashFileIsDeterministic() throws {
        try write("a.txt", "contenu")
        try write("b.txt", "contenu")
        let hashA = try LibraryScanner.hashFile(at: root.appendingPathComponent("a.txt"))
        let hashB = try LibraryScanner.hashFile(at: root.appendingPathComponent("b.txt"))
        XCTAssertEqual(hashA, hashB)
        XCTAssertEqual(hashA.count, 64) // SHA-256 hex
    }
}
