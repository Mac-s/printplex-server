import Fluent

struct CreateLibrariesSchema: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("libraries")
            .id()
            .field("name", .string, .required)
            .field("relative_path", .string, .required)
            .unique(on: "relative_path")
            .field("date_added", .datetime, .required)
            .field("sort_order", .int, .required)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("libraries").delete()
    }
}
