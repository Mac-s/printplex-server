import Vapor
import PrintPlexCore

struct ShopifySyncResponse: Content {
    var productCount: Int
    var lastSyncDate: Date?
}

/// The dashboard's "Dupliquer un produit" form pre-fills these from an
/// existing product client-side and lets the user edit them before sending —
/// so whatever arrives here is exactly what gets created, no server-side
/// template lookup involved. Only `title` is required.
struct ShopifyCreateProductRequest: Content {
    var title: String
    var bodyHtml: String?
    var vendor: String?
    var productType: String?
    var tags: String?
    var price: String?
    var metafields: [ShopifyMetafieldInput]?
}

struct ShopifyController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let shopify = routes.grouped("api", "shopify")
        shopify.get("products", use: products)
        shopify.post("products", use: createProduct)
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
    func createProduct(req: Request) async throws -> ShopifyProduct {
        let body = try req.content.decode(ShopifyCreateProductRequest.self)
        guard !body.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "Le titre est obligatoire")
        }
        do {
            return try await cache(req).createProduct(
                title: body.title, bodyHtml: body.bodyHtml, vendor: body.vendor,
                productType: body.productType, tags: body.tags, price: body.price,
                metafields: body.metafields ?? []
            )
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
