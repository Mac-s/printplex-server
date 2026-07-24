import Fluent
import Foundation
import PrintPlexCore

final class FileModel: Model, @unchecked Sendable {
    static let schema = "files"

    @ID(key: .id) var id: UUID?
    @OptionalParent(key: "project_id") var project: ProjectModel?
    @Field(key: "path") var path: String
    @Field(key: "file_name") var fileName: String
    @Field(key: "file_extension") var fileExtension: String
    @Field(key: "file_size") var fileSize: Int64
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "modified_at") var modifiedAt: Date
    @OptionalField(key: "content_hash") var contentHash: String?
    // Enums stored as raw strings to keep the SQLite schema readable
    @Field(key: "kind") var kindRaw: String
    @Field(key: "file_role") var fileRoleRaw: String
    @Field(key: "cloud_status") var cloudStatusRaw: String
    @Field(key: "tags") var tags: [String]
    @OptionalField(key: "source_app") var sourceApp: String?
    @OptionalField(key: "mesh_stats") var meshStats: MeshStatsDTO?
    @OptionalField(key: "print_params") var printParams: PrintParamsDTO?

    init() {}

    var kind: FileKind { FileKind(rawValue: kindRaw) ?? .other }
    var fileRole: FileRole { FileRole(rawValue: fileRoleRaw) ?? .other }
    var cloudStatus: CloudStatus { CloudStatus(rawValue: cloudStatusRaw) ?? .local }

    func apply(_ scanned: ScannedFile) {
        path = scanned.path
        fileName = scanned.fileName
        fileExtension = scanned.fileExtension
        fileSize = scanned.fileSize
        createdAt = scanned.createdAt
        modifiedAt = scanned.modifiedAt
        if let hash = scanned.contentHash { contentHash = hash }
        kindRaw = scanned.kind.rawValue
        fileRoleRaw = scanned.fileRole.rawValue
        cloudStatusRaw = scanned.cloudStatus.rawValue
        if $tags.value == nil { tags = [] }
    }

    func toDTO() -> FileDTO {
        FileDTO(
            id: id ?? UUID(),
            path: path,
            fileName: fileName,
            fileExtension: fileExtension,
            fileSize: fileSize,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            contentHash: contentHash,
            kind: kind,
            fileRole: fileRole,
            tags: tags,
            cloudStatus: cloudStatus,
            sourceApp: sourceApp,
            meshStats: meshStats,
            printParams: printParams
        )
    }
}
