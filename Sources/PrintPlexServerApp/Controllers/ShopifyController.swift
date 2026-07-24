import Vapor
import PrintPlexCore

struct ShopifySyncResponse: Content {
    var productCount: Int
    var lastSyncDate: Date?
}

struct ShopifyController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let shopify = routes.grouped("api", "shopify")
        shopify.get("products", use: products)
        shopify.post("sync", use: sync)
    }

    @Sendable
    func products(req: Request) async throws -> [ShopifyProduct] {
        try await cache(req).productsSyncingIfNeeded()
    }

    @Sendable
    func sync(req: Request) async throws -> ShopifySyncResponse {
        let cache = try cache(req)
        let count = try await cache.sync()
        return ShopifySyncResponse(productCount: count, lastSyncDate: await cache.lastSyncDate)
    }

    private func cache(_ req: Request) throws -> ShopifyCache {
        guard let cache = req.application.shopifyCache else {
            throw Abort(.serviceUnavailable, reason: "Shopify non configuré (SHOPIFY_STORE_DOMAIN / SHOPIFY_ACCESS_TOKEN)")
        }
        return cache
    }
}
