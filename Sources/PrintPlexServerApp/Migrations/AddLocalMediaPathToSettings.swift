import Fluent

/// The container never knows what host path PRINTPLEX_MEDIA_PATH is actually
/// bind-mounted from — this lets the user tell the dashboard directly, so
/// a project's folder path (as seen inside the container) can be turned back
/// into something meaningful to open/copy on their own machine.
struct AddLocalMediaPathToSettings: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("app_settings")
            .field("local_media_path", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("app_settings")
            .deleteField("local_media_path")
            .update()
    }
}
