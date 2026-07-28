import Fluent

/// Lets a project be marked as actually printed (as opposed to just modeled/sliced) —
/// a manual checkbox, not something a scan can infer.
struct AddAlreadyPrintedToProjects: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("projects")
            .field("already_printed", .bool)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("projects")
            .deleteField("already_printed")
            .update()
    }
}
