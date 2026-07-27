import Foundation
import Crypto

// MARK: - Self-Write Tracker

/// Thread-safe registry of folders the scanner's owner wrote into recently.
/// Used to ignore the file-watcher echo of our own info.json writes,
/// which would otherwise trigger a needless library rescan.
public final class SelfWriteTracker: @unchecked Sendable {
    public static let shared = SelfWriteTracker()

    private let lock = NSLock()
    private var entries: [String: Date] = [:]
    private let window: TimeInterval = 5

    /// Records that we just wrote inside the given folder.
    public func register(_ folderPath: String) {
        let path = URL(fileURLWithPath: folderPath).standardizedFileURL.path
        lock.lock()
        entries[path] = Date()
        // Prune expired entries opportunistically
        let cutoff = Date().addingTimeInterval(-window)
        entries = entries.filter { $0.value > cutoff }
        lock.unlock()
    }

    /// Whether the given event path is covered by a recent self-write.
    /// Watcher event paths can be the file itself or its directory.
    public func isSelfWrite(_ eventPath: String) -> Bool {
        let path = URL(fileURLWithPath: eventPath).standardizedFileURL.path
        let cutoff = Date().addingTimeInterval(-window)
        lock.lock()
        defer { lock.unlock() }
        return entries.contains { folder, date in
            date > cutoff && (path == folder || path.hasPrefix(folder + "/"))
        }
    }
}

// MARK: - LibraryScanner

/// Platform-neutral port of the app's ScannerService: same bottom-up project
/// detection, but decoupled from SwiftData. The caller provides the sets of
/// already-known paths (from its own database) and consumes the event stream.
public enum LibraryScanner {

    /// NAS housekeeping folders that show up throughout the tree on network
    /// shares (created at every level, not just the root) — never real user
    /// content, so never worth surfacing as "unsorted" files. `.skipsHiddenFiles`
    /// doesn't catch these since none of them start with a dot.
    static let ignoredFolderNames: Set<String> = [
        "@eaDir", "@SynoResource", "@sharesnap", ".SynologyWorkingDirectory",
        "#recycle", "$RECYCLE.BIN", "System Volume Information",
    ]

    /// Per-file NAS sidecar suffixes — e.g. Synology stores a file's extended
    /// attributes (Finder metadata, resource forks…) as a *separate* file named
    /// `originalname@SynoEAStream` next to it when served over NFS/SMB, since
    /// those protocols can't carry them inline the way AFP/native filesystems
    /// can. Matched case-insensitively since NFS/SMB clients don't always
    /// agree on the casing they report.
    static let ignoredFileSuffixes: [String] = ["@SynoEAStream"]

    /// Progressively scans `root` using bottom-up project detection.
    /// Emits events for every file found, flagging each as new, existing, or unchanged.
    /// When `lastScanDate` is provided, files not modified since then are marked as unchanged
    /// so the consumer can skip expensive DB updates while still tracking their paths.
    public static func scan(root: URL,
                            knownProjectPaths: Set<String> = [],
                            knownFilePaths: Set<String> = [],
                            lastScanDate: Date? = nil) -> AsyncStream<ScanEvent> {
        let rootPath = root.standardizedFileURL.path

        return AsyncStream { continuation in
            // `Task.detached` never inherits the priority of its caller (unlike
            // plain `Task { }`), so this needs its own explicit low priority —
            // setting it on the caller's task alone wouldn't reach here. Full
            // recursive filesystem enumeration is exactly the kind of bulk
            // work that should never compete with request handling for
            // cooperative-thread-pool time. Currently only the server (which
            // wants this) drives this function — the macOS app still has its
            // own separate ScannerService.swift — so revisit this if/when the
            // app is migrated onto PrintPlexCore and gets its own manual-scan
            // caller with different responsiveness expectations.
            Task.detached(priority: .background) {
                let fm = FileManager.default

                // --- Pass 1: Enumerate ALL files recursively ---
                #if os(macOS)
                let resourceKeys: [URLResourceKey] = [
                    .fileSizeKey, .creationDateKey, .contentModificationDateKey,
                    .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
                    .isDirectoryKey,
                ]
                #else
                let resourceKeys: [URLResourceKey] = [
                    .fileSizeKey, .creationDateKey, .contentModificationDateKey,
                    .isDirectoryKey,
                ]
                #endif

                guard let enumerator = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: resourceKeys,
                    options: [.skipsHiddenFiles]
                ) else {
                    continuation.finish()
                    return
                }

                // Manual iteration (rather than the `for`/`compactMap` sugar) so
                // `skipDescendants()` can prune NAS housekeeping folders entirely
                // instead of walking into e.g. a large @eaDir thumbnail cache
                // just to discard every file found inside it afterwards.
                var allURLs: [URL] = []
                while let url = enumerator.nextObject() as? URL {
                    let name = url.lastPathComponent
                    if Self.ignoredFolderNames.contains(name) {
                        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                        if isDir { enumerator.skipDescendants() }
                        continue
                    }
                    let lowerName = name.lowercased()
                    if Self.ignoredFileSuffixes.contains(where: { lowerName.hasSuffix($0.lowercased()) }) {
                        continue
                    }
                    allURLs.append(url)
                }
                var scannedFiles: [String: ScannedFile] = [:]
                // Track which files were unchanged (skipped full scan)
                var unchangedPaths: Set<String> = []

                for url in allURLs {
                    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    if isDir { continue }

                    // Incremental: skip full scan for files unchanged since lastScanDate
                    if let cutoff = lastScanDate {
                        let modified = (try? url.resourceValues(
                            forKeys: [.contentModificationDateKey]
                        ))?.contentModificationDate

                        if let modified, modified <= cutoff,
                           knownFilePaths.contains(url.standardizedFileURL.path) {
                            // File exists in DB and hasn't changed — create lightweight entry
                            // just for project resolution (path + extension + role)
                            if let lightweight = Self.lightweightEntry(url) {
                                scannedFiles[lightweight.path] = lightweight
                                unchangedPaths.insert(lightweight.path)
                            }
                            continue
                        }
                    }

                    if let scanned = Self.scanSingleFile(url) {
                        scannedFiles[scanned.path] = scanned
                    }
                }

                // --- Pass 2: Resolve projects bottom-up ---
                var projectFolders: Set<String> = []

                // 2a. Primary detection: info.json marks a project folder.
                // Date-named grouping folders ("2026-04", "Apr 2026") are never
                // projects, even if a stray info.json ended up inside them.
                for file in scannedFiles.values {
                    let fileURL = URL(fileURLWithPath: file.path)
                    if fileURL.lastPathComponent.lowercased() == "info.json" {
                        let parentURL = fileURL.deletingLastPathComponent().standardizedFileURL
                        let parentDir = parentURL.path
                        if parentDir != rootPath,
                           !Self.isDateGroupingFolder(parentURL.lastPathComponent) {
                            projectFolders.insert(parentDir)
                        }
                    }
                }

                // 2b. Fallback: model parts create projects only if
                // they are not already inside an info.json project
                let infoPrefixes = projectFolders.map { $0 + "/" }
                for file in scannedFiles.values where file.fileRole == .modelPart {
                    let alreadyCovered = infoPrefixes.contains { file.path.hasPrefix($0) }
                    if alreadyCovered { continue }

                    let fileURL = URL(fileURLWithPath: file.path)
                    let projectDir = Self.resolveProjectFolder(
                        for: fileURL, root: rootPath
                    )

                    if let projectDir, projectDir != rootPath {
                        projectFolders.insert(projectDir)
                    }
                }

                // --- Pass 3: Assign each file to its deepest matching project ---
                // Sort project folders by depth (deepest first) so each file
                // is assigned to its most specific project.
                let sortedProjects = projectFolders.sorted {
                    $0.components(separatedBy: "/").count > $1.components(separatedBy: "/").count
                }
                let projectPrefixes = sortedProjects.map { $0 + "/" }

                var fileToProject: [String: String] = [:]
                for file in scannedFiles.values {
                    for (i, prefix) in projectPrefixes.enumerated() {
                        if file.path.hasPrefix(prefix) {
                            fileToProject[file.path] = sortedProjects[i]
                            break // deepest match wins
                        }
                    }
                }

                // Yield project events
                for folderPath in projectFolders.sorted() {
                    let folderURL = URL(fileURLWithPath: folderPath)

                    let info = Self.parseProjectInfo(in: folderURL)

                    continuation.yield(.projectDiscovered(
                        ScannedProject(
                            name: info?.nom ?? folderURL.lastPathComponent,
                            folderPath: folderPath,
                            info: info
                        ),
                        isNew: !knownProjectPaths.contains(folderPath)
                    ))

                    let projectFiles = scannedFiles.values.filter {
                        fileToProject[$0.path] == folderPath
                    }

                    for file in projectFiles {
                        continuation.yield(.fileScanned(
                            file,
                            projectPath: folderPath,
                            isNew: !knownFilePaths.contains(file.path),
                            isUnchanged: unchangedPaths.contains(file.path)
                        ))
                    }

                    continuation.yield(.projectComplete(projectPath: folderPath))
                }

                // --- Pass 4: Orphan files (not assigned to any project) ---
                for file in scannedFiles.values where fileToProject[file.path] == nil {
                    continuation.yield(.unsortedFileScanned(
                        file,
                        isNew: !knownFilePaths.contains(file.path),
                        isUnchanged: unchangedPaths.contains(file.path)
                    ))
                }

                continuation.finish()
            }
        }
    }

    // MARK: - Bottom-Up Project Resolution

    /// Whether a folder name looks like a date-based grouping folder.
    /// Matches "2026-04" (sortable format) and "Apr 2026" / "Juin 2026"
    /// (month name + year). Date folders group projects, they are never
    /// projects themselves.
    public static func isDateGroupingFolder(_ name: String) -> Bool {
        // "2026-04" or "2026-04-15"
        if name.range(of: #"^\d{4}-\d{2}(-\d{2})?$"#, options: .regularExpression) != nil {
            return true
        }
        // "Apr 2026", "June 2026", "Juin 2026"…
        if name.range(of: #"^[A-Za-zÀ-ÿ]{3,} \d{4}$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// Given a model file URL, resolve the project folder using depth-based logic.
    ///
    /// Convention: first-level folders under the root are always grouping folders,
    /// and date-named folders ("2026-04", "Apr 2026") at any level are also
    /// grouping folders. The project is the first non-date folder below those.
    /// Everything deeper is internal sub-organization.
    static func resolveProjectFolder(
        for fileURL: URL, root rootPath: String
    ) -> String? {
        let filePath = fileURL.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        guard filePath.hasPrefix(rootPrefix) else { return nil }

        let relativePath = String(filePath.dropFirst(rootPrefix.count))
        let components = relativePath.split(separator: "/").map(String.init)

        // Need at least 3 components: group/project/file
        // Files at depth 0 (in root) or depth 1 (in grouping folder) are orphans
        guard components.count >= 3 else { return nil }

        // Skip additional date-named grouping levels after the first-level folder
        // (e.g. Root/Posters/2026-04/MonProjet/file.stl → project = MonProjet)
        var projectIdx = 1
        while projectIdx < components.count - 1, isDateGroupingFolder(components[projectIdx]) {
            projectIdx += 1
        }

        // The project folder must still have at least the file below it
        guard projectIdx < components.count - 1 else { return nil }

        return rootPrefix + components[0...projectIdx].joined(separator: "/")
    }

    /// Parses an `info.json` file in the given project folder, if present.
    public static func parseProjectInfo(in folderURL: URL) -> ProjectInfo? {
        let infoURL = folderURL.appendingPathComponent("info.json")
        guard let data = try? Data(contentsOf: infoURL) else { return nil }
        return try? JSONDecoder().decode(ProjectInfo.self, from: data)
    }

    /// Updates the `info.json` file for a project, preserving any unknown keys.
    /// Creates the file if it doesn't exist yet.
    /// Registers the write in `SelfWriteTracker` so a file-watcher can ignore
    /// the echo of our own writes instead of triggering a rescan.
    public static func updateProjectInfo(
        in folderPath: String,
        update: (inout ProjectInfo) -> Void
    ) throws {
        SelfWriteTracker.shared.register(folderPath)
        let folderURL = URL(fileURLWithPath: folderPath)
        let infoURL = folderURL.appendingPathComponent("info.json")

        // Read existing JSON as a dictionary to preserve unknown keys
        var dict: [String: Any]
        if let data = try? Data(contentsOf: infoURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = existing
        } else {
            dict = [:]
        }

        // Decode current info (or start fresh)
        var info: ProjectInfo
        if let data = try? Data(contentsOf: infoURL),
           let decoded = try? JSONDecoder().decode(ProjectInfo.self, from: data) {
            info = decoded
        } else {
            info = ProjectInfo()
        }

        // Apply the mutation
        update(&info)

        // Merge known fields back into the dictionary. Built manually field by
        // field rather than round-tripping through JSONEncoder: Swift's default
        // Encodable synthesis calls encodeIfPresent for Optional properties,
        // which *omits* nil values from the output instead of encoding `null`.
        // That would mean `update` clearing a field back to nil never reaches
        // the file — the merge loop would just never see that key and the old
        // value on disk would stick around forever.
        let knownFields: [String: Any?] = [
            "nom": info.nom,
            "description": info.description,
            "categorie": info.categorie,
            "createur": info.createur,
            "tags": info.tags,
            "fichiers": info.fichiers,
            "materiaux_suggeres": info.materiaux_suggeres,
            "multi_couleur": info.multi_couleur,
            "notes": info.notes,
            "image_principale": info.image_principale,
            "shopify_product_id": info.shopify_product_id,
        ]
        for (key, value) in knownFields {
            dict[key] = value ?? NSNull()
        }

        // Remove null entries for cleanliness
        for (key, value) in dict {
            if value is NSNull {
                dict.removeValue(forKey: key)
            }
        }

        // Write back with pretty printing
        let output = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        )
        try output.write(to: infoURL, options: .atomic)
    }

    // MARK: - Intelligent info.json Generation

    /// Common 3D-printing filament/resin materials to detect from file & folder names.
    public static let knownMaterials = [
        "PLA", "PLA+", "PETG", "TPU", "ABS", "ASA", "Nylon", "PC",
        "PVA", "HIPS", "Resin", "Wood", "Silk", "Carbon", "PA"
    ]

    /// Builds a suggested `ProjectInfo` for a newly discovered project that has no
    /// `info.json` yet. Suggestions favor reusing the existing vocabulary so that
    /// categories, materials and tags stay consistent (avoids duplicates like
    /// "Spiderman" vs "Spider-man").
    public static func generateProjectInfo(
        folderName: String,
        fileNames: [String],
        existingCategories: [String],
        existingMaterials: [String],
        existingTags: [String]
    ) -> ProjectInfo {
        // Normalized corpus (folder name is weighted by appearing first).
        let corpus = collapseAlphanumeric(([folderName] + fileNames).joined(separator: " "))

        // Materials: existing vocabulary first, then well-known material keywords.
        var materials: [String] = []
        for material in existingMaterials + knownMaterials {
            let needle = collapseAlphanumeric(material)
            guard needle.count >= 3 else { continue }
            if corpus.contains(needle),
               !materials.contains(where: { collapseAlphanumeric($0) == needle }) {
                materials.append(material)
            }
        }

        // Category: reuse an existing category if it appears in the corpus.
        let category = existingCategories.first { cat in
            let needle = collapseAlphanumeric(cat)
            return needle.count >= 3 && corpus.contains(needle)
        }

        // Tags: reuse existing tags that appear in the corpus.
        var tags: [String] = []
        for tag in existingTags {
            let needle = collapseAlphanumeric(tag)
            guard needle.count >= 3 else { continue }
            if corpus.contains(needle), !tags.contains(tag) {
                tags.append(tag)
            }
        }

        return ProjectInfo(
            nom: folderName,
            description: nil,
            categorie: category,
            createur: nil,
            tags: tags.isEmpty ? nil : tags,
            fichiers: nil,
            materiaux_suggeres: materials.isEmpty ? nil : materials,
            multi_couleur: nil,
            notes: nil
        )
    }

    /// Lowercases, strips diacritics, and removes every non-alphanumeric character
    /// so that "Spider-Man" and "spiderman" compare equal.
    private static func collapseAlphanumeric(_ s: String) -> String {
        let folded = s.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init))
    }

    #if os(macOS)
    /// Triggers iCloud download for a cloud-only file. macOS only —
    /// a Linux server sees a plain filesystem and never needs this.
    public static func startDownload(at url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
    #endif

    // MARK: - Lightweight Entry (for unchanged files)

    /// Creates a minimal ScannedFile for unchanged files, just enough for project resolution.
    /// Avoids reading all resource values — only needs path, extension, and role.
    private static func lightweightEntry(
        _ fileURL: URL
    ) -> ScannedFile? {
        // Standardized so prefix matching against the (standardized) root and
        // project folders works even when the root is reached via a symlink
        // (e.g. /var → /private/var on macOS).
        let path = fileURL.standardizedFileURL.path
        let ext = fileURL.pathExtension.lowercased()
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let role = FileRole.from(extension: ext, fileName: fileName)

        return ScannedFile(
            path: path,
            fileName: fileName,
            fileExtension: ext,
            fileSize: 0,
            createdAt: .distantPast,
            modifiedAt: .distantPast,
            contentHash: nil,
            kind: FileKind.from(extension: ext),
            cloudStatus: .local,
            fileRole: role
        )
    }

    // MARK: - Single File Scanner

    private static func scanSingleFile(
        _ fileURL: URL
    ) -> ScannedFile? {
        // Standardized for consistent prefix matching — see lightweightEntry.
        let path = fileURL.standardizedFileURL.path

        do {
            #if os(macOS)
            let resourceValues = try fileURL.resourceValues(forKeys: [
                .fileSizeKey, .creationDateKey, .contentModificationDateKey,
                .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
            ])
            #else
            let resourceValues = try fileURL.resourceValues(forKeys: [
                .fileSizeKey, .creationDateKey, .contentModificationDateKey,
            ])
            #endif

            let ext = fileURL.pathExtension.lowercased()
            let fileSize = Int64(resourceValues.fileSize ?? 0)
            let created = resourceValues.creationDate ?? Date()
            let modified = resourceValues.contentModificationDate ?? Date()
            let cloudStatus = resolveCloudStatus(resourceValues)
            let fileName = fileURL.deletingPathExtension().lastPathComponent
            let role = FileRole.from(extension: ext, fileName: fileName)

            // Skip hashing during scan — too expensive for large 3D files.
            // Hash can be computed on-demand when actually needed.
            let hash: String? = nil

            return ScannedFile(
                path: path,
                fileName: fileName,
                fileExtension: ext,
                fileSize: fileSize,
                createdAt: created,
                modifiedAt: modified,
                contentHash: hash,
                kind: FileKind.from(extension: ext),
                cloudStatus: cloudStatus,
                fileRole: role
            )
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private static func resolveCloudStatus(_ values: URLResourceValues) -> CloudStatus {
        #if os(macOS)
        guard let downloadStatus = values.ubiquitousItemDownloadingStatus else {
            return .local
        }
        if let isDownloading = values.ubiquitousItemIsDownloading, isDownloading {
            return .downloading
        }
        switch downloadStatus {
        case .current, .downloaded:
            return .local
        case .notDownloaded:
            return .cloudOnly
        default:
            return .local
        }
        #else
        return .local
        #endif
    }

    /// SHA-256 content hash, for on-demand deduplication / change detection.
    public static func hashFile(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
