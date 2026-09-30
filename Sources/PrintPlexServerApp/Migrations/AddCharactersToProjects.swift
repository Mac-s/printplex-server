import Fluent

/// Character names (Luigi, Bane, Jean Grey…), split out of `tags` — most of
/// them only ever apply to a single project, which was drowning the
/// cross-cutting tags in the sidebar filter list. Optional at the DB level
/// like `source_hardware`/`source_instruction_images` (not required like
/// `tags`): existing rows predate this column and would have no value for a
/// required one — see `ProjectModel.characters`.
struct AddCharactersToProjects: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("projects")
            .field("characters", .json)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("projects")
            .deleteField("characters")
            .update()
    }
}
