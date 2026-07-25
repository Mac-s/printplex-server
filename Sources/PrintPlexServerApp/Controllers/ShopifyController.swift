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
        do {
            return try await cache(req).productsSyncingIfNeeded()
        } catch {
            throw Self.abortify(error)
        }
    }

    @Sendable
    func sync(req: Request) async throws -> ShopifySyncResponse {
        let cache = try cache(req)
        do {
            let count = try await cache.sync()
            return ShopifySyncResponse(productCount: count, lastSyncDate: await cache.lastSyncDate)
        } catch {
            throw Self.abortify(error)
        }
    }

    private func cache(_ req: Request) throws -> ShopifyCache {
        guard let cache = req.application.shopifyCache else {
            throw Abort(.serviceUnavailable, reason: "Shopify non configuré (SHOPIFY_STORE_DOMAIN / SHOPIFY_ACCESS_TOKEN)")
        }
        return cache
    }

    /// ShopifyError's whole point is a French, user-facing `errorDescription`
    /// — but Vapor's default error middleware only special-cases `AbortError`
    /// and otherwise serializes the raw Swift description (e.g. `httpError(404)`).
    /// Route every Shopify-facing failure through this so the API — and the
    /// dashboard reading its `reason` field — shows the friendly message.
    static func abortify(_ error: Error) -> Abort {
        if let abort = error as? Abort { return abort }
        let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return Abort(.badGateway, reason: reason)
    }
}
