import Fluent

/// Adds per-plate mesh stats storage for multi-plate BambuStudio .3mf files —
/// `mesh_stats` keeps describing plate 0 only (backward compatible), this new
/// column holds one entry per plate when there's more than one.
struct AddPlateStatsToFiles: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("files")
            .field("plate_stats", .json)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("files")
            .deleteField("plate_stats")
            .update()
    }
}
