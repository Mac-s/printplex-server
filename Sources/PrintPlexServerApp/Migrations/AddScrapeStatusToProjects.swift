import Fluent

/// Tracks an in-flight (or last-failed) request to the ForgeCore relay —
/// the small script that runs on the user's own machine (where the
/// authenticated scraping session lives) and scrapes+imports a design when
/// asked to via the dashboard. Deliberately DB-only: unlike the rest of the
/// `source_*` columns, this is transient job state, not descriptive data
/// about the design, so it's never mirrored to info.json.
struct AddScrapeStatusToProjects: AsyncMigration {
    // Separate `.update()` calls, not one with both `.field(...)` chained:
    // SQLite's `ALTER TABLE` only accepts a single `ADD COLUMN` per statement.
    func prepare(on database: Database) async throws {
        try await database.schema("projects")
            .field("source_scrape_status", .string)
            .update()
        try await database.schema("projects")
            .field("source_scrape_error", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("projects")
            .deleteField("source_scrape_status")
            .update()
        try await database.schema("projects")
            .deleteField("source_scrape_error")
            .update()
    }
}
