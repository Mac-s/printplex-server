import Vapor
import Fluent
import PrintPlexCore

/// Progress event pushed to SSE subscribers during a scan.
struct ScanProgressEvent: Codable, Sendable {
    var type: String            // scanStarted | projectDiscovered | projectComplete | meshParsed | scanCompleted | error
    var projectName: String?
    var path: String?
    var projectsFound: Int?
    var filesFound: Int?
    var message: String?
}

struct ScanState: Sendable {
    var isScanning: Bool
    var lastScanDate: Date?
    var lastScanProjects: Int
    var lastScanFiles: Int
}

/// Owns the scan pipeline: walks the library with LibraryScanner, mirrors the
/// results into SQLite, then parses 3MF geometry for new/changed files.
/// Serialized by design — a second scan request while one is running is a no-op.
actor ScanService {
    private let app: Application
    private let config: AppConfig

    private var isScanning = false
    private var lastScanDate: Date?
    private var lastScanProjects = 0
    private var lastScanFiles = 0
    private var subscribers: [UUID: AsyncStream<ScanProgressEvent>.Continuation] = [:]

    init(app: Application, config: AppConfig) {
        self.app = app
        self.config = config
    }

    // MARK: - State & subscriptions

    func state() -> ScanState {
        ScanState(isScanning: isScanning,
                  lastScanDate: lastScanDate,
                  lastScanProjects: lastScanProjects,
                  lastScanFiles: lastScanFiles)
    }

    func subscribe() -> AsyncStream<ScanProgressEvent> {
        AsyncStream { continuation in
            let id = UUID()
            subscribers[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func broadcast(_ event: ScanProgressEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    // MARK: - Scan pipeline

    /// Returns false when a scan was already in progress.
    @discardableResult
    func runScan() async -> Bool {
        guard !isScanning else { return false }
        isScanning = true
        defer { isScanning = false }

        do {
            try await performScan()
        } catch {
            app.logger.report(error: error)
            broadcast(ScanProgressEvent(type: "error", message: String(describing: error)))
        }
        return true
    }

    private func performScan() async throws {
        let db = app.db
        let root = URL(fileURLWithPath: config.libraryPath)
        broadcast(ScanProgressEvent(type: "scanStarted", path: config.libraryPath))

        let existingProjects = try await ProjectModel.query(on: db).all()
        var projectsByPath: [String: ProjectModel] = [:]
        for project in existingProjects { projectsByPath[project.folderPath] = project }

        let existingFiles = try await FileModel.query(on: db).all()
        var filesByPath: [String: FileModel] = [:]
        for file in existingFiles { filesByPath[file.path] = file }

        var seenProjects: Set<String> = []
        var seenFiles: Set<String> = []
        var projectMaxModified: [String: Date] = [:]

        for await event in LibraryScanner.scan(
            root: root,
            knownProjectPaths: Set(projectsByPath.keys),
            knownFilePaths: Set(filesByPath.keys),
            lastScanDate: lastScanDate
        ) {
            switch event {
            case .projectDiscovered(let scanned, _):
                seenProjects.insert(scanned.folderPath)
                let model = projectsByPath[scanned.folderPath] ?? ProjectModel()
                if model.id == nil {
                    model.folderPath = scanned.folderPath
                    model.dateAdded = Date()
                    model.lastModifiedAt = Date()
                    model.tags = []
                    model.suggestedMaterials = []
                }
                model.name = scanned.name
                model.apply(info: scanned.info)
                try await model.save(on: db)
                projectsByPath[scanned.folderPath] = model
                broadcast(ScanProgressEvent(type: "projectDiscovered",
                                            projectName: scanned.name,
                                            path: scanned.folderPath,
                                            projectsFound: seenProjects.count,
                                            filesFound: seenFiles.count))

            case .fileScanned(let scanned, let projectPath, _, let isUnchanged):
                seenFiles.insert(scanned.path)
                if !isUnchanged {
                    let current = projectMaxModified[projectPath] ?? .distantPast
                    if scanned.modifiedAt > current {
                        projectMaxModified[projectPath] = scanned.modifiedAt
                    }
                }
                try await upsertFile(scanned, projectID: projectsByPath[projectPath]?.id,
                                     isUnchanged: isUnchanged, into: &filesByPath, on: db)

            case .unsortedFileScanned(let scanned, _, let isUnchanged):
                seenFiles.insert(scanned.path)
                try await upsertFile(scanned, projectID: nil,
                                     isUnchanged: isUnchanged, into: &filesByPath, on: db)

            case .projectComplete(let projectPath):
                broadcast(ScanProgressEvent(type: "projectComplete", path: projectPath,
                                            projectsFound: seenProjects.count,
                                            filesFound: seenFiles.count))
            }
        }

        // Remove DB entries whose files disappeared from disk
        for (path, model) in filesByPath where !seenFiles.contains(path) {
            try await model.delete(on: db)
            filesByPath[path] = nil
        }
        for (path, model) in projectsByPath where !seenProjects.contains(path) {
            try await model.delete(on: db)
            projectsByPath[path] = nil
        }

        // Reflect the newest file modification on each project
        for (path, model) in projectsByPath {
            if let maxModified = projectMaxModified[path], maxModified > model.lastModifiedAt {
                model.lastModifiedAt = maxModified
                try await model.save(on: db)
            }
        }

        // Mesh parsing pass: new or changed 3MF files
        let toParse = filesByPath.values.filter { file in
            file.fileExtension == "3mf" &&
            (file.meshStats == nil || (file.meshStats?.parsedAt ?? .distantPast) < file.modifiedAt)
        }
        for file in toParse {
            let path = file.path
            let parsed = try? await Task.detached(priority: .utility) {
                try ThreeMFParser.parse(URL(fileURLWithPath: path))
            }.value
            guard let parsed else { continue }
            file.meshStats = MeshStatsDTO(from: parsed, parsedAt: Date())
            try await file.save(on: db)
            broadcast(ScanProgressEvent(type: "meshParsed", path: path))
        }

        lastScanDate = Date()
        lastScanProjects = seenProjects.count
        lastScanFiles = seenFiles.count
        broadcast(ScanProgressEvent(type: "scanCompleted",
                                    projectsFound: seenProjects.count,
                                    filesFound: seenFiles.count))
        app.logger.info("Scan terminé : \(seenProjects.count) projets, \(seenFiles.count) fichiers")
    }

    private func upsertFile(_ scanned: ScannedFile, projectID: UUID?,
                            isUnchanged: Bool,
                            into filesByPath: inout [String: FileModel],
                            on db: Database) async throws {
        if let existing = filesByPath[scanned.path] {
            if !isUnchanged {
                existing.apply(scanned)
            }
            if existing.$project.id != projectID {
                existing.$project.id = projectID
            }
            if existing.hasChanges {
                try await existing.save(on: db)
            }
        } else {
            let model = FileModel()
            model.apply(scanned)
            model.$project.id = projectID
            try await model.save(on: db)
            filesByPath[scanned.path] = model
        }
    }
}
