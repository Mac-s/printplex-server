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
    func coverAndCounts(from files: [FileModel]) -> (coverFileId: UUID?, partsCount: Int, totalFileCount: Int, imageCount: Int) {
        let images = files.filter { $0.fileRoleRaw == FileRole.renderImage.rawValue }
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
