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
               partsCount: Int = 0, totalFileCount: Int = 0, imageCount: Int = 0) -> ProjectDTO {
        ProjectDTO(
            id: id ?? UUID(),
            name: name,
            folderPath: folderPath,
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
            shopifyProductId: shopifyProductId,
            files: files,
            coverFileId: coverFileId,
            partsCount: partsCount,
            totalFileCount: totalFileCount,
            imageCount: imageCount
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
}
