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
    /// The single admin account for the web dashboard — nil means no account
    /// exists yet (`AuthController`'s one-time `/api/auth/setup` route stays
    /// open until this is set). `adminPasswordHash` is a Bcrypt hash, never
    /// the plaintext password.
    @OptionalField(key: "admin_username") var adminUsername: String?
    @OptionalField(key: "admin_password_hash") var adminPasswordHash: String?
    /// Lets other services (the ForgeCore relay, the native client) call the
    /// API without a browser session — sent as the `X-API-Key` header. Shown
    /// in plaintext in Réglages once logged in, same trust model as the
    /// Shopify access token above.
    @OptionalField(key: "api_key") var apiKey: String?

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
