import Vapor
import Fluent
import PrintPlexCore

/// Backs the ForgeCore relay: a small script that runs on the user's own
/// machine (where the authenticated ForgeCore/Playwright session lives),
/// polls `pending` for projects the dashboard has asked to be scraped, does
/// the actual scraping+import locally, and posts the result back here —
/// the server itself never touches ForgeCore or holds any login session.
struct ForgeCorePendingProject: Content {
    var id: UUID
    var name: String
    var sourceUrl: String
}

struct ForgeCorePhotoPayload: Content {
    /// Destination filename only (e.g. "forgecore-gallery-1.webp") — never a
    /// path; sanitized server-side before touching disk regardless.
    var filename: String
    var dataBase64: String
}

struct ForgeCoreImportResultRequest: Content {
    var success: Bool
    var error: String?
    var description: String?
    var sourceHardware: [String]?
    var sourceEstimatedWeight: String?
    var sourceEstimatedPrintTime: String?
    /// Written to `gallery/`, `users-gallery/`, `instructions/` respectively
    /// — same subfolder layout import.js already uses for a manual import,
    /// so the two ways of importing a design produce identical project
    /// folders. Instruction photos are recorded separately (as
    /// "instructions/<name>" paths) so the dashboard keeps excluding them
    /// from the main photo gallery/cover selection.
    var galleryPhotos: [ForgeCorePhotoPayload]?
    var communityPhotos: [ForgeCorePhotoPayload]?
    var instructionPhotos: [ForgeCorePhotoPayload]?
}

struct ForgeCoreController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("api", "forgecore", "pending", use: pending)
        // Base64-encoded photos push this well past Vapor's 16kb default body
        // size limit — raised just for this route rather than globally, since
        // nothing else needs to accept multi-megabyte request bodies.
        routes.on(.POST, "api", "projects", ":projectID", "forgecore-import-result",
                  body: .collect(maxSize: "50mb"), use: importResult)
    }

    @Sendable
    func pending(req: Request) async throws -> [ForgeCorePendingProject] {
        // Compared against a local `let`, not an inline string literal —
        // mirrors `\.$kindRaw == kindRaw` in FileController rather than
        // `\.$field == "literal"`, which has tripped Fluent's key-path type
        // inference before.
        let pendingStatus = "pending"
        let models = try await ProjectModel.query(on: req.db)
            .filter(\.$sourceScrapeStatus == pendingStatus)
            .all()
        return models.compactMap { model in
            guard let id = model.id, let url = model.sourceUrl else { return nil }
            return ForgeCorePendingProject(id: id, name: model.name, sourceUrl: url)
        }
    }

    /// Writes any scraped photos into the project's folder, merges the
    /// scraped metadata into the DB + info.json (same convention as
    /// import.js: a (re-)scrape always overwrites these fields with the
    /// freshest source data), clears the pending status, and triggers a
    /// rescan so the new files show up. On failure, just records the error
    /// for the dashboard to display.
    @Sendable
    func importResult(req: Request) async throws -> ProjectDTO {
        let model = try await find(req)
        let body = try req.content.decode(ForgeCoreImportResultRequest.self)

        guard body.success else {
            model.sourceScrapeStatus = "failed"
            model.sourceScrapeError = body.error ?? "Échec inconnu"
            try await model.save(on: req.db)
            return try await projectDTO(for: model, on: req.db)
        }

        let folder = URL(fileURLWithPath: model.folderPath, isDirectory: true)
        for photo in body.galleryPhotos ?? [] {
            try writePhoto(photo, into: folder, subfolder: "gallery")
        }
        for photo in body.communityPhotos ?? [] {
            try writePhoto(photo, into: folder, subfolder: "users-gallery")
        }
        var instructionFilenames = model.sourceInstructionImages ?? []
        for photo in body.instructionPhotos ?? [] {
            let relativePath = try writePhoto(photo, into: folder, subfolder: "instructions")
            instructionFilenames.append(relativePath)
        }

        // Matches import.js's own convention: a (re-)scrape always overwrites
        // these fields with the freshest data from the source, same as
        // hardware/weight/print-time — the user asked for this explicitly
        // by pasting the URL and clicking "(Re)lancer le scraping".
        if let d = body.description { model.projectDescription = d }
        if let h = body.sourceHardware { model.sourceHardware = h }
        if let w = body.sourceEstimatedWeight { model.sourceEstimatedWeight = w }
        if let t = body.sourceEstimatedPrintTime { model.sourceEstimatedPrintTime = t }
        if !instructionFilenames.isEmpty { model.sourceInstructionImages = instructionFilenames }
        model.sourceScrapeStatus = nil
        model.sourceScrapeError = nil
        try await model.save(on: req.db)

        try LibraryScanner.updateProjectInfo(in: model.folderPath) { info in
            if let d = body.description { info.description = d }
            if let h = body.sourceHardware { info.source_hardware = h }
            if let w = body.sourceEstimatedWeight { info.source_estimated_weight = w }
            if let t = body.sourceEstimatedPrintTime { info.source_estimated_print_time = t }
            if !instructionFilenames.isEmpty { info.source_instruction_images = instructionFilenames }
        }

        // Wait for the scan so the response already reflects the new files —
        // the relay call is a one-shot background job, not a page load, so
        // there's no responsiveness reason to fire-and-forget it here.
        await req.application.scanService.runScan()

        return try await projectDTO(for: model, on: req.db)
    }

    /// Refetches the model + its files so the returned DTO's counts/cover
    /// reflect reality — needed after a rescan (success path), but just as
    /// correct to reuse on the failure path instead of the all-zero counts
    /// `model.toDTO()`'s defaults would otherwise report.
    private func projectDTO(for model: ProjectModel, on db: Database) async throws -> ProjectDTO {
        let refreshed = try await ProjectModel.find(model.requireID(), on: db) ?? model
        let files = try await FileModel.query(on: db)
            .filter(\.$project.$id == refreshed.requireID())
            .all()
        let (coverFileId, partsCount, totalFileCount, imageCount) = refreshed.coverAndCounts(from: files)
        return refreshed.toDTO(coverFileId: coverFileId, partsCount: partsCount,
                               totalFileCount: totalFileCount, imageCount: imageCount)
    }

    /// Writes into `<project>/<subfolder>/<safe filename>`, returning that
    /// path relative to the project folder (e.g. "instructions/foo.webp") —
    /// what gets recorded in `sourceInstructionImages`.
    @discardableResult
    private func writePhoto(_ photo: ForgeCorePhotoPayload, into folder: URL, subfolder: String) throws -> String {
        guard let data = Data(base64Encoded: photo.dataBase64) else {
            throw Abort(.badRequest, reason: "Photo \(photo.filename) : données base64 invalides")
        }
        // Never trust a filename from the network as a literal path
        // component — collapse it to its last component before writing.
        let safeName = (photo.filename as NSString).lastPathComponent
        guard !safeName.isEmpty, safeName != ".", safeName != ".." else {
            throw Abort(.badRequest, reason: "Nom de fichier invalide : \(photo.filename)")
        }
        let destDir = folder.appendingPathComponent(subfolder, isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try data.write(to: destDir.appendingPathComponent(safeName))
        return "\(subfolder)/\(safeName)"
    }

    private func find(_ req: Request) async throws -> ProjectModel {
        guard let id = req.parameters.get("projectID", as: UUID.self),
              let model = try await ProjectModel.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Projet introuvable")
        }
        return model
    }
}
