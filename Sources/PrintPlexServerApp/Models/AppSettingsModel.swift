import Fluent
import Foundation

/// Singleton settings row — mirrors what the macOS app kept in UserDefaults
/// (autoScanEnabled, scanIntervalMinutes, Shopify credentials), now shared
/// server-side so every client sees the same configuration.
final class AppSettingsModel: Model, @unchecked Sendable {
    static let schema = "app_settings"

    /// Fixed id: there is exactly one settings row.
    static let singletonID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @ID(key: .id) var id: UUID?
    @Field(key: "auto_scan_enabled") var autoScanEnabled: Bool
    @Field(key: "scan_interval_minutes") var scanIntervalMinutes: Int
    @OptionalField(key: "shopify_store_domain") var shopifyStoreDomain: String?
    @OptionalField(key: "shopify_access_token") var shopifyAccessToken: String?
    /// The host path that PRINTPLEX_MEDIA_PATH (the container's media root)
    /// is actually bind-mounted from — never known to the container itself,
    /// so it's just a user-entered string used client-side to turn a
    /// project's container path into one that means something on their own
    /// machine (see ProjectController's `localFolderPath`).
    @OptionalField(key: "local_media_path") var localMediaPath: String?

    init() {}

    init(autoScanEnabled: Bool, scanIntervalMinutes: Int,
         shopifyStoreDomain: String?, shopifyAccessToken: String?) {
        self.id = Self.singletonID
        self.autoScanEnabled = autoScanEnabled
        self.scanIntervalMinutes = scanIntervalMinutes
        self.shopifyStoreDomain = shopifyStoreDomain
        self.shopifyAccessToken = shopifyAccessToken
    }

    static func loadOrCreate(on db: Database, defaultAutoScanEnabled: Bool,
                            defaultScanIntervalMinutes: Int,
                            seedShopifyStoreDomain: String?,
                            seedShopifyAccessToken: String?) async throws -> AppSettingsModel {
        if let existing = try await AppSettingsModel.find(singletonID, on: db) {
            return existing
        }
        let model = AppSettingsModel(
            autoScanEnabled: defaultAutoScanEnabled,
            scanIntervalMinutes: defaultScanIntervalMinutes,
            shopifyStoreDomain: seedShopifyStoreDomain,
            shopifyAccessToken: seedShopifyAccessToken
        )
        try await model.save(on: db)
        return model
    }
}
