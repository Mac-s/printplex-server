import Foundation
import PrintPlexCore

/// Caches the Shopify product list server-side so clients don't each hit the
/// Admin API (mirrors what the desktop app kept in its @Observable service).
actor ShopifyCache {
    private let client: ShopifyClient
    private(set) var products: [ShopifyProduct] = []
    private(set) var lastSyncDate: Date?

    init(credentials: ShopifyCredentials) {
        self.client = ShopifyClient(credentials: credentials)
    }

    @discardableResult
    func sync() async throws -> Int {
        products = try await client.fetchAllProducts()
        lastSyncDate = Date()
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

    nonisolated func url(for product: ShopifyProduct) -> URL? {
        client.productURL(for: product)
    }
}
