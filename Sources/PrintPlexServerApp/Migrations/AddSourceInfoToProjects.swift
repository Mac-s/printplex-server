import Fluent

/// Lets a project carry a link back to the design's original page (e.g. a
/// ForgeCore design URL), the hardware it requires, the designer's own
/// weight/print-time estimate (kept separate from PrintPlex's own computed
/// estimate — they're not the same thing and shouldn't be conflated), and
/// the filenames of imported assembly-instruction images (so they can be
/// shown in their own section instead of mixed into the product photo
/// gallery). Filled in by hand or via an external import, never by a scan.
struct AddSourceInfoToProjects: AsyncMigration {
    // Separate `.update()` calls, not one with all `.field(...)` chained:
    // SQLite's `ALTER TABLE` only accepts a single `ADD COLUMN` per statement,
    // and Fluent's SQLite driver batches chained `.field()` calls on one
    // `.update()` into one such statement, which fails outright.
    func prepare(on database: Database) async throws {
        try await database.schema("projects")
            .field("source_url", .string)
            .update()
        try await database.schema("projects")
            .field("source_hardware", .json)
            .update()
        try await database.schema("projects")
            .field("source_estimated_weight", .string)
            .update()
        try await database.schema("projects")
            .field("source_estimated_print_time", .string)
            .update()
        try await database.schema("projects")
            .field("source_instruction_images", .json)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("projects")
            .deleteField("source_url")
            .update()
        try await database.schema("projects")
            .deleteField("source_hardware")
            .update()
        try await database.schema("projects")
            .deleteField("source_estimated_weight")
            .update()
        try await database.schema("projects")
            .deleteField("source_estimated_print_time")
            .update()
        try await database.schema("projects")
            .deleteField("source_instruction_images")
            .update()
    }
}
