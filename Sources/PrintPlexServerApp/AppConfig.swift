import Vapor
import PrintPlexCore

/// Server configuration, sourced from environment variables (docker-compose friendly).
struct AppConfig: Sendable {
    /// Root of the 3D print library (mounted volume in Docker).
    let libraryPath: String
    /// Where the server keeps its own state (SQLite DB, thumbnail cache).
    let dataPath: String
    /// Periodic rescan interval; 0 disables both the boot scan and the timer.
    let scanIntervalMinutes: Int
    let shopifyCredentials: ShopifyCredentials?
    /// Use an in-memory SQLite database (tests).
    let inMemoryDatabase: Bool

    static func fromEnvironment() -> AppConfig {
        let library = Environment.get("PRINTPLEX_LIBRARY_PATH") ?? "./Library"
        let data = Environment.get("PRINTPLEX_DATA_PATH") ?? "./data"
        let interval = Environment.get("PRINTPLEX_SCAN_INTERVAL_MIN").flatMap(Int.init) ?? 15

        let credentials = ShopifyCredentials(
            storeDomain: Environment.get("SHOPIFY_STORE_DOMAIN") ?? "",
            accessToken: Environment.get("SHOPIFY_ACCESS_TOKEN") ?? ""
        )

        return AppConfig(
            libraryPath: URL(fileURLWithPath: library).standardizedFileURL.path,
            dataPath: URL(fileURLWithPath: data).standardizedFileURL.path,
            scanIntervalMinutes: interval,
            shopifyCredentials: credentials.isConfigured ? credentials : nil,
            inMemoryDatabase: Environment.get("PRINTPLEX_DB_IN_MEMORY") == "1"
        )
    }

    var databasePath: String { dataPath + "/printplex.sqlite" }
    var thumbnailsPath: String { dataPath + "/thumbnails" }
}

// MARK: - Application storage

struct AppConfigKey: StorageKey { typealias Value = AppConfig }
struct ScanServiceKey: StorageKey { typealias Value = ScanService }
struct ShopifyCacheKey: StorageKey { typealias Value = ShopifyCache }

extension Application {
    var appConfig: AppConfig {
        get { storage[AppConfigKey.self]! }
        set { storage[AppConfigKey.self] = newValue }
    }
    var scanService: ScanService {
        get { storage[ScanServiceKey.self]! }
        set { storage[ScanServiceKey.self] = newValue }
    }
    var shopifyCache: ShopifyCache? {
        get { storage[ShopifyCacheKey.self] }
        set { storage[ShopifyCacheKey.self] = newValue }
    }
}
