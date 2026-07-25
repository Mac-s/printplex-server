import Vapor
import Fluent
import PrintPlexCore

let printPlexServerVersion = "0.1.0"

struct SettingsOverview: Content {
    var serverVersion: String
    var mediaPath: String
    var dataPath: String
    var autoScanEnabled: Bool
    var scanIntervalMinutes: Int
    var shopifyStoreDomain: String
    var shopifyConfigured: Bool
    var shopifyProductCount: Int
    var shopifyLastSyncDate: Date?
    var shopifySyncError: String?
}

struct ScanSettingsUpdateRequest: Content {
    var autoScanEnabled: Bool?
    var scanIntervalMinutes: Int?
}

struct ShopifySettingsResponse: Content {
    var storeDomain: String
    var accessToken: String
    var configured: Bool
}

struct ShopifySettingsUpdateRequest: Content {
    var storeDomain: String
    var accessToken: String
}

/// Backs the web dashboard's "Réglages" menu — the server-side equivalent of
/// the macOS app's Settings window. The individual scan roots ("libraries")
/// live in `LibraryController`/`LibraryModel`; this covers the generic media
/// root (fixed at container boot via PRINTPLEX_MEDIA_PATH), scan cadence, and
/// Shopify credentials.
struct SettingsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let settings = routes.grouped("api", "settings")
        settings.get(use: overview)
        settings.patch("scan", use: updateScan)
        settings.get("shopify", use: shopify)
        settings.put("shopify", use: updateShopify)
    }

    @Sendable
    func overview(req: Request) async throws -> SettingsOverview {
        let scanSettings = await req.application.scanService.currentScanSettings()
        let config = req.application.appConfig

        var storeDomain = ""
        var configured = false
        var productCount = 0
        var lastSyncDate: Date?
        var syncError: String?
        if let cache = req.application.shopifyCache {
            let creds = await cache.credentials
            storeDomain = creds.storeDomain
            configured = creds.isConfigured
            productCount = await cache.products.count
            lastSyncDate = await cache.lastSyncDate
            syncError = await cache.syncError
        }

        return SettingsOverview(
            serverVersion: printPlexServerVersion,
            mediaPath: config.mediaPath,
            dataPath: config.dataPath,
            autoScanEnabled: scanSettings.autoScanEnabled,
            scanIntervalMinutes: scanSettings.scanIntervalMinutes,
            shopifyStoreDomain: storeDomain,
            shopifyConfigured: configured,
            shopifyProductCount: productCount,
            shopifyLastSyncDate: lastSyncDate,
            shopifySyncError: syncError
        )
    }

    @Sendable
    func updateScan(req: Request) async throws -> ScanSettings {
        let body = try req.content.decode(ScanSettingsUpdateRequest.self)
        return try await req.application.scanService.updateScanSettings(
            autoScanEnabled: body.autoScanEnabled,
            scanIntervalMinutes: body.scanIntervalMinutes
        )
    }

    /// Includes the plaintext access token so the edit form can be prefilled —
    /// same trust model as the macOS app, which stores it unencrypted in
    /// UserDefaults. Acceptable for a personal server on a private network.
    @Sendable
    func shopify(req: Request) async throws -> ShopifySettingsResponse {
        guard let row = try await AppSettingsModel.find(AppSettingsModel.singletonID, on: req.db) else {
            return ShopifySettingsResponse(storeDomain: "", accessToken: "", configured: false)
        }
        let creds = ShopifyCredentials(storeDomain: row.shopifyStoreDomain ?? "",
                                       accessToken: row.shopifyAccessToken ?? "")
        return ShopifySettingsResponse(storeDomain: creds.storeDomain,
                                       accessToken: creds.accessToken,
                                       configured: creds.isConfigured)
    }

    @Sendable
    func updateShopify(req: Request) async throws -> ShopifySettingsResponse {
        let body = try req.content.decode(ShopifySettingsUpdateRequest.self)
        let credentials = ShopifyCredentials(storeDomain: body.storeDomain, accessToken: body.accessToken)

        guard let row = try await AppSettingsModel.find(AppSettingsModel.singletonID, on: req.db) else {
            throw Abort(.internalServerError, reason: "Ligne de réglages absente")
        }
        row.shopifyStoreDomain = credentials.storeDomain
        row.shopifyAccessToken = credentials.accessToken
        try await row.save(on: req.db)

        if let cache = req.application.shopifyCache {
            await cache.updateCredentials(credentials)
        } else if credentials.isConfigured {
            req.application.shopifyCache = ShopifyCache(credentials: credentials)
        }

        return ShopifySettingsResponse(storeDomain: credentials.storeDomain,
                                       accessToken: credentials.accessToken,
                                       configured: credentials.isConfigured)
    }
}
