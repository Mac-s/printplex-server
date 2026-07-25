import Fluent

struct CreateSettingsSchema: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("printers")
            .id()
            .field("name", .string, .required)
            .field("build_x", .double, .required)
            .field("build_y", .double, .required)
            .field("build_z", .double, .required)
            .field("perimeter_speed_mmps", .double, .required)
            .field("infill_speed_mmps", .double, .required)
            .field("nozzle_diameter_mm", .double, .required)
            .field("default_layer_height_mm", .double, .required)
            .field("supports_percent", .double, .required)
            .field("purge_percent", .double, .required)
            .field("speed_efficiency", .double, .required)
            .field("sort_order", .int, .required)
            .create()

        try await database.schema("materials")
            .id()
            .field("name", .string, .required)
            .field("density_g_cm3", .double, .required)
            .field("price_per_kg", .double, .required)
            .field("sort_order", .int, .required)
            .create()

        try await database.schema("app_settings")
            .id()
            .field("auto_scan_enabled", .bool, .required)
            .field("scan_interval_minutes", .int, .required)
            .field("shopify_store_domain", .string)
            .field("shopify_access_token", .string)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("app_settings").delete()
        try await database.schema("materials").delete()
        try await database.schema("printers").delete()
    }
}
