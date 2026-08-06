import Fluent

/// Backs the single admin account (web dashboard login) and the API key
/// (other services, e.g. the ForgeCore relay or the native client) — see
/// `AuthController`.
struct AddAuthToSettings: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("app_settings")
            .field("admin_username", .string)
            .update()
        try await database.schema("app_settings")
            .field("admin_password_hash", .string)
            .update()
        try await database.schema("app_settings")
            .field("api_key", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("app_settings")
            .deleteField("admin_username")
            .update()
        try await database.schema("app_settings")
            .deleteField("admin_password_hash")
            .update()
        try await database.schema("app_settings")
            .deleteField("api_key")
            .update()
    }
}
