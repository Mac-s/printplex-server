import Vapor
import Fluent
import PrintPlexCore

struct LibraryCreateRequest: Content {
    var name: String
    /// Relative to the media root, e.g. "Figurines" or "" for the whole root.
    var relativePath: String
}

struct BrowseResponse: Content {
    var path: String
    var parentPath: String?
    var directories: [String]
}

/// Manages the Plex-style "libraries" — folders under the generic mounted
/// media root (`AppConfig.mediaPath`) that the scanner walks. Configured at
/// runtime from the Settings UI instead of a single env-var-fixed path.
struct LibraryController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let libraries = routes.grouped("api", "libraries")
        libraries.get(use: index)
        libraries.post(use: create)
        libraries.get("browse", use: browse)
        libraries.group(":libraryID") { library in
            library.delete(use: delete)
        }
    }

    @Sendable
    func index(req: Request) async throws -> [LibraryDTO] {
        try await LibraryModel.query(on: req.db).sort(\.$sortOrder).all().map { $0.toDTO() }
    }

    @Sendable
    func create(req: Request) async throws -> LibraryDTO {
        let body = try req.content.decode(LibraryCreateRequest.self)
        let mediaPath = req.application.appConfig.mediaPath
        let relativePath = try Self.validatedRelativePath(body.relativePath, mediaPath: mediaPath)

        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw Abort(.badRequest, reason: "Le nom de la bibliothèque ne peut pas être vide")
        }

        let absolutePath = relativePath.isEmpty ? mediaPath
            : URL(fileURLWithPath: mediaPath).appendingPathComponent(relativePath).standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDir), isDir.boolValue else {
            throw Abort(.badRequest, reason: "Ce dossier n'existe pas dans le répertoire média")
        }

        if try await LibraryModel.query(on: req.db)
            .filter(\.$relativePath == relativePath)
            .first() != nil {
            throw Abort(.conflict, reason: "Ce dossier est déjà une bibliothèque")
        }

        let maxOrder = try await LibraryModel.query(on: req.db).max(\.$sortOrder) ?? -1
        let model = LibraryModel(name: name, relativePath: relativePath, sortOrder: maxOrder + 1)
        try await model.save(on: req.db)

        // New library, empty results so far — worth a scan without making the
        // caller wait for it (mirrors the "Scanner maintenant" button).
        Task.detached(priority: .background) { await req.application.scanService.runScan() }

        return model.toDTO()
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("libraryID", as: UUID.self),
              let model = try await LibraryModel.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Bibliothèque introuvable")
        }
        try await model.delete(on: req.db)
        // Projects/files that were under this folder stop being "seen" by the
        // next scan and get cleaned up by its usual stale-entry removal —
        // same mechanism that already handles files deleted from disk.
        return .noContent
    }

    /// Lists subdirectories under `mediaPath/path`, for the folder-picker in
    /// the Settings UI (mirrors Plex's "browse for folder" dialog when adding
    /// a library). Only directories are listed — files aren't pickable.
    @Sendable
    func browse(req: Request) async throws -> BrowseResponse {
        let mediaPath = req.application.appConfig.mediaPath
        let requested = (try? req.query.get(String.self, at: "path")) ?? ""
        let relativePath = try Self.validatedRelativePath(requested, mediaPath: mediaPath)
        let absolutePath = relativePath.isEmpty ? mediaPath
            : URL(fileURLWithPath: mediaPath).appendingPathComponent(relativePath).standardizedFileURL.path

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDir), isDir.boolValue else {
            throw Abort(.notFound, reason: "Ce dossier n'existe pas dans le répertoire média")
        }

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: absolutePath)) ?? []
        let directories = entries
            .filter { !$0.hasPrefix(".") }
            .filter { entry in
                var d: ObjCBool = false
                FileManager.default.fileExists(atPath: absolutePath + "/" + entry, isDirectory: &d)
                return d.boolValue
            }
            .sorted()

        let parentPath: String?
        if relativePath.isEmpty {
            parentPath = nil
        } else {
            let components = relativePath.split(separator: "/")
            parentPath = components.count > 1 ? components.dropLast().joined(separator: "/") : ""
        }

        return BrowseResponse(path: relativePath, parentPath: parentPath, directories: directories)
    }

    /// Normalizes a client-supplied relative path and rejects anything that
    /// would escape the media root (`..`, absolute paths elsewhere…) — same
    /// defense-in-depth spirit as `FileController.safePath`.
    static func validatedRelativePath(_ raw: String, mediaPath: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !trimmed.isEmpty else { return "" }

        let candidate = URL(fileURLWithPath: mediaPath).appendingPathComponent(trimmed).standardizedFileURL.path
        let mediaPrefix = mediaPath.hasSuffix("/") ? mediaPath : mediaPath + "/"
        guard candidate == mediaPath || candidate.hasPrefix(mediaPrefix) else {
            throw Abort(.badRequest, reason: "Ce chemin sort du répertoire média")
        }
        // Re-derive the relative path from the standardized absolute path so
        // "./foo/../foo/bar" and similar are normalized consistently.
        return candidate == mediaPath ? "" : String(candidate.dropFirst(mediaPrefix.count))
    }
}
