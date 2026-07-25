import Vapor
import Fluent
import PrintPlexCore

struct FileKindCounts: Content {
    var stl: Int
    var threeMF: Int
    var obj: Int
    var step: Int
    var other: Int
    var unsorted: Int
}

/// Only `manualWorkLevel` is ever set from the UI (mirrors the macOS detail
/// view's per-file difficulty picker) — the other PrintParams fields aren't
/// user-editable anywhere yet.
struct FileUpdateRequest: Content {
    var manualWorkLevel: String?
}

struct FileController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let files = routes.grouped("api", "files")
        files.get(use: index)
        files.get("unsorted", use: unsorted)
        files.get("stats", use: stats)
        files.group(":fileID") { file in
            file.get(use: detail)
            file.patch(use: update)
            file.get("download", use: download)
            file.get("thumbnail", use: thumbnail)
            file.get("estimate", use: estimate)
        }
    }

    /// Flat file listing across the whole library (all projects + unsorted),
    /// optionally filtered by kind — backs the sidebar's "Types 3D" section,
    /// which (like the macOS app's equivalent list) shows files without their
    /// project context.
    @Sendable
    func index(req: Request) async throws -> [FileDTO] {
        var query = FileModel.query(on: req.db)
        if let kindRaw = try? req.query.get(String.self, at: "kind"), !kindRaw.isEmpty {
            query = query.filter(\.$kindRaw == kindRaw)
        }
        let models = try await query.sort(\.$fileName).all()
        return models.map { $0.toDTO() }
    }

    @Sendable
    func unsorted(req: Request) async throws -> [FileDTO] {
        let models = try await FileModel.query(on: req.db)
            .filter(\.$project.$id == .null)
            .sort(\.$fileName)
            .all()
        return models.map { $0.toDTO() }
    }

    /// Counts backing the sidebar badges — kept as a single aggregate query
    /// rather than making the client fetch every file just to count them.
    @Sendable
    func stats(req: Request) async throws -> FileKindCounts {
        async let stl = FileModel.query(on: req.db).filter(\.$kindRaw == FileKind.stl.rawValue).count()
        async let threeMF = FileModel.query(on: req.db).filter(\.$kindRaw == FileKind.threeMF.rawValue).count()
        async let obj = FileModel.query(on: req.db).filter(\.$kindRaw == FileKind.obj.rawValue).count()
        async let step = FileModel.query(on: req.db).filter(\.$kindRaw == FileKind.step.rawValue).count()
        async let other = FileModel.query(on: req.db).filter(\.$kindRaw == FileKind.other.rawValue).count()
        async let unsorted = FileModel.query(on: req.db).filter(\.$project.$id == .null).count()
        return try await FileKindCounts(
            stl: stl, threeMF: threeMF, obj: obj, step: step, other: other, unsorted: unsorted
        )
    }

    @Sendable
    func detail(req: Request) async throws -> FileDTO {
        try await find(req).toDTO()
    }

    /// Persists the per-file manual-work (difficulty) level chosen in the
    /// print estimate section — same field the macOS app writes to
    /// `file.printParams.manualWorkLevel` in SwiftData.
    @Sendable
    func update(req: Request) async throws -> FileDTO {
        let file = try await find(req)
        let body = try req.content.decode(FileUpdateRequest.self)
        if let level = body.manualWorkLevel {
            var params = file.printParams ?? PrintParamsDTO()
            params.manualWorkLevel = level
            file.printParams = params
        }
        try await file.save(on: req.db)
        return file.toDTO()
    }

    @Sendable
    func download(req: Request) async throws -> Response {
        let file = try await find(req)
        let path = try safePath(for: file, in: req.application.appConfig)
        guard FileManager.default.fileExists(atPath: path) else {
            throw Abort(.notFound, reason: "Fichier absent du disque")
        }
        let response = req.fileio.streamFile(at: path)
        response.headers.replaceOrAdd(
            name: .contentDisposition,
            value: "attachment; filename=\"\(file.fileName).\(file.fileExtension)\""
        )
        return response
    }

    /// Render images are served as-is; 3MF files get their embedded slicer
    /// thumbnail extracted and cached on disk (QuickLook replacement).
    @Sendable
    func thumbnail(req: Request) async throws -> Response {
        let file = try await find(req)
        let config = req.application.appConfig

        let cachePath = config.thumbnailsPath + "/\(try file.requireID().uuidString).png"
        if FileManager.default.fileExists(atPath: cachePath) {
            return req.fileio.streamFile(at: cachePath)
        }

        if file.fileRole == .renderImage {
            let path = try safePath(for: file, in: config)
            guard FileManager.default.fileExists(atPath: path) else { throw Abort(.notFound) }
            return req.fileio.streamFile(at: path)
        }

        if file.kind == .threeMF {
            let path = try safePath(for: file, in: config)
            let data = await Task.detached(priority: .utility) {
                ThreeMFParser.extractThumbnail(at: URL(fileURLWithPath: path))
            }.value
            guard let data else {
                throw Abort(.notFound, reason: "Pas de vignette embarquée dans ce .3mf")
            }
            try? data.write(to: URL(fileURLWithPath: cachePath))
            let response = Response(status: .ok, body: .init(data: data))
            response.headers.contentType = .png
            return response
        }

        throw Abort(.notFound, reason: "Pas de vignette pour ce type de fichier")
    }

    /// Accepts `?plateIndex=N` for multi-plate files (defaults to plate 0).
    @Sendable
    func estimate(req: Request) async throws -> PrintEstimate {
        let file = try await find(req)
        let query = try req.query.decode(EstimateQuery.self)
        guard let stats = EstimateSupport.meshStats(for: file, plateIndex: query.plateIndex) else {
            throw Abort(.conflict, reason: "Pas de statistiques de maillage — lancez un scan d'abord")
        }
        let (printer, material, settings, manual) = try await EstimateSupport.inputs(from: req)
        return PrintEstimator.estimate(
            parsed: EstimateSupport.parserResult(from: stats),
            printer: printer, material: material,
            settings: settings, manualWork: manual
        )
    }

    // MARK: - Helpers

    private func find(_ req: Request) async throws -> FileModel {
        guard let id = req.parameters.get("fileID", as: UUID.self),
              let model = try await FileModel.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Fichier introuvable")
        }
        return model
    }

    /// Defense in depth: never serve anything outside the mounted media root
    /// (every configured library lives under it, by construction).
    private func safePath(for file: FileModel, in config: AppConfig) throws -> String {
        let standardized = URL(fileURLWithPath: file.path).standardizedFileURL.path
        guard standardized == config.mediaPath || standardized.hasPrefix(config.mediaPath + "/") else {
            throw Abort(.forbidden, reason: "Chemin hors du répertoire média")
        }
        return standardized
    }
}
