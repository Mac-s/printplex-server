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
///
/// `imageFileIds` is the one exception to "server does no lookup": it names
/// *local* project files (not Shopify data) whose bytes this controller reads
/// and base64-attaches — the point being to carry a project's own photos onto
/// a duplicated product instead of the template product's photos.
struct ShopifyCreateProductRequest: Content {
    var title: String
    var bodyHtml: String?
    var vendor: String?
    var productType: String?
    var tags: String?
    var variants: [ShopifyVariantInput]?
    var metafields: [ShopifyMetafieldInput]?
    var imageFileIds: [UUID]?
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
        let images = try await resolveImages(fileIds: body.imageFileIds ?? [], req: req)
        do {
            return try await cache(req).createProduct(
                title: body.title, bodyHtml: body.bodyHtml, vendor: body.vendor,
                productType: body.productType, tags: body.tags,
                variants: body.variants ?? [], metafields: body.metafields ?? [],
                images: images
            )
        } catch {
            throw Self.abortify(error)
        }
    }

    /// Reads each named project file straight off disk and base64-encodes it —
    /// a file that's since vanished or moved outside the media root is just
    /// skipped rather than failing the whole product creation over one photo.
    private func resolveImages(fileIds: [UUID], req: Request) async throws -> [ShopifyImageInput] {
        guard !fileIds.isEmpty else { return [] }
        let config = req.application.appConfig
        var images: [ShopifyImageInput] = []
        for fileId in fileIds {
            guard let file = try await FileModel.find(fileId, on: req.db),
                  let path = try? MediaPath.safePath(for: file, in: config),
                  let data = FileManager.default.contents(atPath: path) else { continue }
            images.append(ShopifyImageInput(
                attachment: data.base64EncodedString(),
                filename: "\(file.fileName).\(file.fileExtension)"
            ))
        }
        return images
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
