import Vapor
import Fluent
import PrintPlexCore

struct FileController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let files = routes.grouped("api", "files")
        files.get("unsorted", use: unsorted)
        files.group(":fileID") { file in
            file.get(use: detail)
            file.get("download", use: download)
            file.get("thumbnail", use: thumbnail)
            file.get("estimate", use: estimate)
        }
    }

    @Sendable
    func unsorted(req: Request) async throws -> [FileDTO] {
        let models = try await FileModel.query(on: req.db)
            .filter(\.$project.$id == .null)
            .sort(\.$fileName)
            .all()
        return models.map { $0.toDTO() }
    }

    @Sendable
    func detail(req: Request) async throws -> FileDTO {
        try await find(req).toDTO()
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

    @Sendable
    func estimate(req: Request) async throws -> PrintEstimate {
        let file = try await find(req)
        guard let stats = file.meshStats else {
            throw Abort(.conflict, reason: "Pas de statistiques de maillage — lancez un scan d'abord")
        }
        let (printer, material, settings, manual) = try EstimateSupport.inputs(from: req)
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

    /// Defense in depth: never serve anything outside the library root.
    private func safePath(for file: FileModel, in config: AppConfig) throws -> String {
        let standardized = URL(fileURLWithPath: file.path).standardizedFileURL.path
        guard standardized.hasPrefix(config.libraryPath + "/") else {
            throw Abort(.forbidden, reason: "Chemin hors de la bibliothèque")
        }
        return standardized
    }
}
