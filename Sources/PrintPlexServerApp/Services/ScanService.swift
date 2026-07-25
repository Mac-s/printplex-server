import Vapor
import Fluent
import PrintPlexCore

/// Progress event pushed to SSE subscribers during a scan.
struct ScanProgressEvent: Codable, Sendable {
    var type: String            // scanStarted | libraryStarted | projectDiscovered | projectComplete | meshParsed | scanCompleted | error
    var projectName: String?
    var libraryName: String?
    var path: String?
    var librariesCount: Int?
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

struct ScanSettings: Sendable, Codable {
    var autoScanEnabled: Bool
    var scanIntervalMinutes: Int
}

/// Owns the scan pipeline: walks the library with LibraryScanner, mirrors the
/// results into SQLite, then parses 3MF geometry for new/changed files.
/// Serialized by design — a second scan request while one is running is a no-op.
/// Also owns the persisted auto-scan settings, so the background loop in
/// configure.swift can react to changes made through the settings API without
/// a restart.
actor ScanService {
    private let app: Application
    private let config: AppConfig

    /// The in-flight scan, if any. Modeled as a shared `Task` (rather than a
    /// plain `Bool` flag) so a caller that arrives while a scan is already
    /// running can actually *wait* for it to finish instead of immediately
    /// getting a no-op — which matters now that adding a library triggers an
    /// automatic background scan that a concurrent `?wait=true` call could
    /// otherwise race right past.
    private var scanTask: Task<Void, Never>?
    /// Set by a `runScan()` call that arrives while one is already in
    /// progress. Without this, that request would just join the current
    /// pass and could silently miss whatever prompted it — e.g. two
    /// libraries added back-to-back: the second's auto-triggered scan could
    /// join the first's already-running (and still library-B-blind) pass
    /// instead of ever reading the database again after B was added. See `executeScan()`.
    private var rescanRequested = false
    private var lastScanDate: Date?
    private var lastScanProjects = 0
    private var lastScanFiles = 0
    private var subscribers: [UUID: AsyncStream<ScanProgressEvent>.Continuation] = [:]
    private var settings = ScanSettings(autoScanEnabled: true, scanIntervalMinutes: 15)

    init(app: Application, config: AppConfig) {
        self.app = app
        self.config = config
    }

    // MARK: - Settings (persisted in AppSettingsModel)

    /// Loads the persisted scan settings, seeding the row from `config` on
    /// first boot. Call once during startup, before the periodic loop reads them.
    func bootstrapSettings() async throws {
        let row = try await AppSettingsModel.loadOrCreate(
            on: app.db,
            defaultAutoScanEnabled: config.scanIntervalMinutes > 0,
            defaultScanIntervalMinutes: config.scanIntervalMinutes > 0 ? config.scanIntervalMinutes : 15,
            seedShopifyStoreDomain: config.shopifyCredentials?.storeDomain,
            seedShopifyAccessToken: config.shopifyCredentials?.accessToken
        )
        settings = ScanSettings(autoScanEnabled: row.autoScanEnabled,
                                scanIntervalMinutes: row.scanIntervalMinutes)
    }

    func currentScanSettings() -> ScanSettings { settings }

    @discardableResult
    func updateScanSettings(autoScanEnabled: Bool?, scanIntervalMinutes: Int?) async throws -> ScanSettings {
        guard let row = try await AppSettingsModel.find(AppSettingsModel.singletonID, on: app.db) else {
            throw Abort(.internalServerError, reason: "Ligne de réglages absente")
        }
        if let autoScanEnabled { row.autoScanEnabled = autoScanEnabled }
        if let scanIntervalMinutes { row.scanIntervalMinutes = max(1, scanIntervalMinutes) }
        try await row.save(on: app.db)
        settings = ScanSettings(autoScanEnabled: row.autoScanEnabled,
                                scanIntervalMinutes: row.scanIntervalMinutes)
        return settings
    }

    // MARK: - State & subscriptions

    func state() -> ScanState {
        ScanState(isScanning: scanTask != nil,
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

    /// Returns false when this call joined an already-running scan rather
    /// than starting a new one — either way, the scan has finished, and
    /// reflects whatever prompted this call (e.g. a library added right
    /// before), by the time this returns.
    @discardableResult
    func runScan() async -> Bool {
        if let scanTask {
            rescanRequested = true
            await scanTask.value
            return false
        }
        let task = Task { await self.executeScan() }
        scanTask = task
        await task.value
        return true
    }

    /// Clears `scanTask` as the *last* thing this does, from inside the task
    /// body itself — not after `await task.value` back in `runScan()`. A
    /// `Task`'s `.value` only becomes available to *any* awaiter once its
    /// closure fully returns, so resetting the field here guarantees every
    /// awaiter (the caller that started the scan, and any that joined it)
    /// sees `scanTask == nil` as soon as `.value` unblocks them — regardless
    /// of which one the actor happens to resume first. Doing the reset after
    /// the fact in `runScan()` instead would race: a joiner could resume and
    /// return before the originator's own continuation got a turn to clear
    /// the field, leaving `state()` reporting `isScanning: true` for an
    /// already-finished scan.
    ///
    /// Loops on `rescanRequested` so a `runScan()` call that arrives mid-scan
    /// (setting that flag) is guaranteed at least one full `performScan()`
    /// pass that re-reads the database *after* it arrived — instead of just
    /// joining a pass already underway, which read the library list before
    /// whatever prompted the new call (e.g. a second library being added).
    /// Actor methods run atomically between suspension points, and the only
    /// suspension points here are inside `performScan()`, so a flag set while
    /// it's running is never missed by the check right after it returns.
    private func executeScan() async {
        repeat {
            rescanRequested = false
            do {
                try await performScan()
            } catch {
                app.logger.report(error: error)
                broadcast(ScanProgressEvent(type: "error", message: String(describing: error)))
            }
        } while rescanRequested
        scanTask = nil
    }

    private func performScan() async throws {
        let db = app.db
        let libraries = try await LibraryModel.query(on: db).sort(\.$sortOrder).all()

        broadcast(ScanProgressEvent(type: "scanStarted", librariesCount: libraries.count))

        guard !libraries.isEmpty else {
            // Plex-style empty state: no libraries configured yet, nothing to do.
            lastScanDate = Date()
            lastScanProjects = 0
            lastScanFiles = 0
            broadcast(ScanProgressEvent(type: "scanCompleted", projectsFound: 0, filesFound: 0))
            return
        }

        let existingProjects = try await ProjectModel.query(on: db).all()
        var projectsByPath: [String: ProjectModel] = [:]
        for project in existingProjects { projectsByPath[project.folderPath] = project }

        let existingFiles = try await FileModel.query(on: db).all()
        var filesByPath: [String: FileModel] = [:]
        for file in existingFiles { filesByPath[file.path] = file }

        var seenProjects: Set<String> = []
        var seenFiles: Set<String> = []
        var projectMaxModified: [String: Date] = [:]

        // Each configured library is scanned in turn; results accumulate into
        // the same running dictionaries so the cleanup pass below (which
        // deletes anything not "seen") correctly spans every library instead
        // of wiping out the others' entries after each individual pass.
        for library in libraries {
            let root = URL(fileURLWithPath: library.absolutePath(mediaPath: config.mediaPath))
            broadcast(ScanProgressEvent(type: "libraryStarted", libraryName: library.name, path: root.path))

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
        }

        // Remove DB entries whose files disappeared from disk (or whose
        // library was removed from the config — either way, they simply
        // never showed up as "seen" above).
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
            // Lowest priority: mesh parsing is CPU-bound bulk work that should
            // never compete with request handling for cooperative-pool threads.
            let parsed = try? await Task.detached(priority: .background) {
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
