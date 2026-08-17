import Fluent
import Foundation
import PrintPlexCore

final class ProjectModel: Model, @unchecked Sendable {
    static let schema = "projects"

    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    @Field(key: "folder_path") var folderPath: String
    @Field(key: "last_modified_at") var lastModifiedAt: Date
    @Field(key: "date_added") var dateAdded: Date
    @OptionalField(key: "cover_image_file_name") var coverImageFileName: String?

    // info.json metadata
    @OptionalField(key: "project_description") var projectDescription: String?
    @OptionalField(key: "category") var category: String?
    @OptionalField(key: "creator") var creator: String?
    @Field(key: "tags") var tags: [String]
    @Field(key: "suggested_materials") var suggestedMaterials: [String]
    @OptionalField(key: "multi_color") var multiColor: Bool?
    @OptionalField(key: "notes") var notes: String?
    @OptionalField(key: "shopify_product_id") var shopifyProductId: String?
    @OptionalField(key: "already_printed") var alreadyPrinted: Bool?
    @OptionalField(key: "source_url") var sourceUrl: String?
    // Optional (not @Field like tags/suggestedMaterials) even though the DTO
    // exposes it as a plain array: existing rows predate this column and
    // would have no value for a required one, unlike tags/suggestedMaterials
    // which have been required since the very first migration.
    @OptionalField(key: "source_hardware") var sourceHardware: [String]?
    @OptionalField(key: "source_estimated_weight") var sourceEstimatedWeight: String?
    @OptionalField(key: "source_estimated_print_time") var sourceEstimatedPrintTime: String?
    @OptionalField(key: "source_instruction_images") var sourceInstructionImages: [String]?
    // Not touched by `apply(info:)` — deliberately DB-only, see ProjectDTO.
    @OptionalField(key: "source_scrape_status") var sourceScrapeStatus: String?
    @OptionalField(key: "source_scrape_error") var sourceScrapeError: String?

    @Children(for: \.$project) var files: [FileModel]

    init() {}

    /// Merges info.json values into the model (only fields present in the file).
    func apply(info: ProjectInfo?) {
        guard let info else { return }
        if let d = info.description { projectDescription = d }
        if let c = info.categorie { category = c }
        if let c = info.createur { creator = c }
        if let t = info.tags { tags = t }
        if let m = info.materiaux_suggeres { suggestedMaterials = m }
        if let mc = info.multi_couleur { multiColor = mc }
        if let n = info.notes { notes = n }
        if let img = info.image_principale { coverImageFileName = img }
        if let sid = info.shopify_product_id { shopifyProductId = sid }
        if let p = info.deja_imprime { alreadyPrinted = p }
        if let u = info.source_url { sourceUrl = u }
        if let h = info.source_hardware { sourceHardware = h }
        if let w = info.source_estimated_weight { sourceEstimatedWeight = w }
        if let t = info.source_estimated_print_time { sourceEstimatedPrintTime = t }
        if let ii = info.source_instruction_images { sourceInstructionImages = ii }
    }

    func toDTO(files: [FileDTO]? = nil, coverFileId: UUID? = nil,
               partsCount: Int = 0, totalFileCount: Int = 0, imageCount: Int = 0,
               localFolderPath: String? = nil, hasManualEstimate: Bool = false) -> ProjectDTO {
        ProjectDTO(
            id: id ?? UUID(),
            name: name,
            folderPath: folderPath,
            localFolderPath: localFolderPath,
            lastModifiedAt: lastModifiedAt,
            dateAdded: dateAdded,
            coverImageFileName: coverImageFileName,
            projectDescription: projectDescription,
            category: category,
            creator: creator,
            tags: tags,
            suggestedMaterials: suggestedMaterials,
            multiColor: multiColor,
            notes: notes,
            alreadyPrinted: alreadyPrinted,
            sourceUrl: sourceUrl,
            sourceHardware: sourceHardware ?? [],
            sourceEstimatedWeight: sourceEstimatedWeight,
            sourceEstimatedPrintTime: sourceEstimatedPrintTime,
            sourceInstructionImages: sourceInstructionImages ?? [],
            sourceScrapeStatus: sourceScrapeStatus,
            sourceScrapeError: sourceScrapeError,
            shopifyProductId: shopifyProductId,
            files: files,
            coverFileId: coverFileId,
            partsCount: partsCount,
            totalFileCount: totalFileCount,
            imageCount: imageCount,
            hasManualEstimate: hasManualEstimate
        )
    }

    /// Picks the cover file the same way the macOS app does:
    /// explicit `coverImageFileName` match > first render image > first model part.
    /// Also returns the counts the grid cards need, computed from the same file set.
    /// Imported assembly-instruction images are excluded from `images` here —
    /// they're plain `renderImage`-role files on disk like any photo, but
    /// showing up as the auto-picked cover or inflating the "N photos" count
    /// on a grid card would be wrong; they belong only in their own section.
    func coverAndCounts(from files: [FileModel]) -> (coverFileId: UUID?, partsCount: Int, totalFileCount: Int, imageCount: Int) {
        let instructionNames = Set(sourceInstructionImages ?? [])
        let images = files.filter {
            $0.fileRoleRaw == FileRole.renderImage.rawValue
                && !instructionNames.contains(relativePath(of: $0))
                && !instructionNames.contains("\($0.fileName).\($0.fileExtension)")
        }
        let chosen = coverImageFileName.flatMap { name in
            images.first { "\($0.fileName).\($0.fileExtension)" == name }
        }
        let cover = chosen
            ?? images.first
            ?? files.first { $0.fileRoleRaw == FileRole.modelPart.rawValue }
        let partsCount = files.filter { $0.fileRoleRaw == FileRole.modelPart.rawValue }.count
        return (cover?.id, partsCount, files.count, images.count)
    }

    /// True once at least one file's real print data (the "Impression
    /// réelle" block) has been recorded — backs the "Estimé manuellement"
    /// sidebar filter.
    func hasManualEstimate(from files: [FileModel]) -> Bool {
        files.contains { $0.printParams?.actualPrintTimeSec != nil || $0.printParams?.actualFilamentGrams != nil }
    }

    /// Swaps the container's media root prefix (e.g. "/media") for the host
    /// path the user entered in Réglages ("Chemin local"), so `folderPath`
    /// (only ever meaningful inside the container) becomes something they
    /// can actually open/copy on their own machine. Nil whenever that
    /// setting is empty, or `folderPath` doesn't start with `mediaPath` —
    /// silently returning the raw container path here would be worse than
    /// just not offering a local path at all.
    func localFolderPath(mediaPath: String, localMediaPath: String?) -> String? {
        guard let localMediaPath, !localMediaPath.isEmpty else { return nil }
        guard folderPath.hasPrefix(mediaPath) else { return nil }
        let suffix = folderPath.dropFirst(mediaPath.count)
        let trimmedLocal = localMediaPath.hasSuffix("/") ? String(localMediaPath.dropLast()) : localMediaPath
        return trimmedLocal + suffix
    }

    /// `source_instruction_images` entries from the ForgeCore relay/import.js
    /// are paths relative to the project folder (e.g. "instructions/foo.webp",
    /// since photos are organized into gallery/users-gallery/instructions
    /// subfolders), not bare filenames — this reconstructs that same relative
    /// path from a `FileModel`'s absolute `path` so the two can be compared.
    /// Falls back to the bare filename for older imports that predate the
    /// subfolder convention.
    private func relativePath(of file: FileModel) -> String {
        let prefix = folderPath + "/"
        guard file.path.hasPrefix(prefix) else {
            return "\(file.fileName).\(file.fileExtension)"
        }
        return String(file.path.dropFirst(prefix.count))
    }
}
