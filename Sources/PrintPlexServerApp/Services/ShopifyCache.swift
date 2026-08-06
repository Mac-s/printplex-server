import Foundation
import PrintPlexCore

/// Caches the Shopify product list server-side so clients don't each hit the
/// Admin API (mirrors what the desktop app kept in its @Observable service).
/// Credentials are mutable — the settings API can update them at runtime
/// without a server restart.
actor ShopifyCache {
    private var client: ShopifyClient
    private(set) var products: [ShopifyProduct] = []
    private(set) var lastSyncDate: Date?
    private(set) var syncError: String?

    init(credentials: ShopifyCredentials) {
        self.client = ShopifyClient(credentials: credentials)
    }

    var credentials: ShopifyCredentials { client.credentials }

    /// Replaces the credentials and clears the cache, since the new store
    /// almost certainly has a different product catalog.
    func updateCredentials(_ credentials: ShopifyCredentials) {
        client = ShopifyClient(credentials: credentials)
        products = []
        lastSyncDate = nil
        syncError = nil
    }

    @discardableResult
    func sync() async throws -> Int {
        do {
            products = try await client.fetchAllProducts(onMetafieldsError: { productId, error in
                // `print` rather than a logging framework dependency — this
                // just needs to land in `docker compose logs`, and a scope/
                // permissions error here otherwise looks identical to "this
                // product genuinely has no metafields" from every other angle.
                print("[ShopifyCache] Échec de récupération des métadonnées pour le produit \(productId) : \(error)")
            })
            lastSyncDate = Date()
            syncError = nil
        } catch {
            syncError = error.localizedDescription
            throw error
        }
        return products.count
    }

    /// Returns the cached products, syncing once lazily on first access.
    func productsSyncingIfNeeded() async throws -> [ShopifyProduct] {
        if lastSyncDate == nil {
            try await sync()
        }
        return products
    }

    func match(projectName: String, explicitProductId: String?) -> ShopifyProduct? {
        ShopifyClient.matchProduct(in: products,
                                   projectName: projectName,
                                   explicitProductId: explicitProductId)
    }

    func url(for product: ShopifyProduct) -> URL? {
        client.productURL(for: product)
    }

    /// Creates a new product on Shopify from explicit field values (the caller
    /// — the web dashboard's duplicate-product form — already resolved
    /// whatever it wants copied from a template) and folds it straight into
    /// the cache, so it shows up immediately without waiting for the next
    /// full sync.
    func createProduct(title: String, bodyHtml: String?, vendor: String?, productType: String?,
                        tags: String?, variants: [ShopifyVariantInput], metafields: [ShopifyMetafieldInput],
                        images: [ShopifyImageInput], collections: [ShopifyCollectionRef],
                        category: ShopifyCategoryRef?, categoryMetafields: [ShopifyMetafieldInput]) async throws -> ShopifyProduct {
        let created = try await client.createProduct(
            title: title, bodyHtml: bodyHtml, vendor: vendor, productType: productType,
            tags: tags, variants: variants, metafields: metafields, images: images,
            collections: collections, category: category, categoryMetafields: categoryMetafields,
            onCollectionError: { collectionId, error in
                print("[ShopifyCache] Échec d'ajout à la collection \(collectionId) : \(error)")
            },
            onCategoryError: { stage, error in
                print("[ShopifyCache] Échec (\(stage)) : \(error)")
            }
        )
        products.append(created)
        return created
    }
}
