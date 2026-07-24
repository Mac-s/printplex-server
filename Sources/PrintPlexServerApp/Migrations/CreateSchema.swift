import Fluent

struct CreateSchema: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("projects")
            .id()
            .field("name", .string, .required)
            .field("folder_path", .string, .required)
            .unique(on: "folder_path")
            .field("last_modified_at", .datetime, .required)
            .field("date_added", .datetime, .required)
            .field("cover_image_file_name", .string)
            .field("project_description", .string)
            .field("category", .string)
            .field("creator", .string)
            .field("tags", .json, .required)
            .field("suggested_materials", .json, .required)
            .field("multi_color", .bool)
            .field("notes", .string)
            .field("shopify_product_id", .string)
            .create()

        try await database.schema("files")
            .id()
            .field("project_id", .uuid, .references("projects", "id", onDelete: .cascade))
            .field("path", .string, .required)
            .unique(on: "path")
            .field("file_name", .string, .required)
            .field("file_extension", .string, .required)
            .field("file_size", .int64, .required)
            .field("created_at", .datetime, .required)
            .field("modified_at", .datetime, .required)
            .field("content_hash", .string)
            .field("kind", .string, .required)
            .field("file_role", .string, .required)
            .field("cloud_status", .string, .required)
            .field("tags", .json, .required)
            .field("source_app", .string)
            .field("mesh_stats", .json)
            .field("print_params", .json)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("files").delete()
        try await database.schema("projects").delete()
    }
}
