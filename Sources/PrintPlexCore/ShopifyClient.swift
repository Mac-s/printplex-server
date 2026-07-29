import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Shopify Data Models

public struct ShopifyProduct: Codable, Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let status: String       // "active" | "draft" | "archived"
    public let handle: String
    public let variants: [ShopifyVariant]
    public let bodyHtml: String?
    /// Raw comma-separated string, exactly as Shopify's REST API returns it
    /// (not an array) — use `tagList` for individual tags.
    public let tags: String
    public let productType: String?
    public let vendor: String?
    /// Not part of the `products.json` response at any `fields=` setting —
    /// populated separately via `ShopifyClient.fetchMetafields(productId:)`
    /// and merged in by `fetchAllProducts()`. Empty until then.
    public var metafields: [ShopifyMetafield]
    public let images: [ShopifyImage]

    public init(id: Int, title: String, status: String, handle: String, variants: [ShopifyVariant],
                bodyHtml: String? = nil, tags: String = "", productType: String? = nil,
                vendor: String? = nil, metafields: [ShopifyMetafield] = [],
                images: [ShopifyImage] = []) {
        self.id = id
        self.title = title
        self.status = status
        self.handle = handle
        self.variants = variants
        self.bodyHtml = bodyHtml
        self.tags = tags
        self.productType = productType
        self.vendor = vendor
        self.metafields = metafields
        self.images = images
    }

    // Shopify's own wire format (snake_case) — used *only* by the custom
    // decoder below, to parse `products.json` responses. Deliberately not
    // named `CodingKeys`: naming it that would make the compiler reuse this
    // same snake_case mapping to *synthesize* `encode(to:)` too, which is
    // wrong — encoding here means serializing *our own* API response for the
    // dashboard's JS, which reads camelCase (`product.bodyHtml`). Keeping
    // this decode-only meant `encode(to:)` was actually round-tripping
    // `body_html`/`product_type` straight back out to the browser, which had
    // no property by that name and silently read `undefined` — this file no
    // longer declares a `CodingKeys` type at all, so Swift synthesizes
    // `encode(to:)` on its own using the plain (camelCase) property names.
    private enum ShopifyWireKeys: String, CodingKey {
        case id, title, status, handle, variants, tags, vendor, metafields, images
        case bodyHtml = "body_html"
        case productType = "product_type"
    }

    // Custom decode: `metafields` is never present when decoding a
    // `products.json` response (it's fetched separately), and the other new
    // fields are defensively optional in case a future `fields=` tweak omits
    // one — same decodeIfPresent pattern as PrinterProfile in PrintEstimator.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ShopifyWireKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        status = try c.decode(String.self, forKey: .status)
        handle = try c.decode(String.self, forKey: .handle)
        variants = try c.decodeIfPresent([ShopifyVariant].self, forKey: .variants) ?? []
        bodyHtml = try c.decodeIfPresent(String.self, forKey: .bodyHtml)
        tags = try c.decodeIfPresent(String.self, forKey: .tags) ?? ""
        productType = try c.decodeIfPresent(String.self, forKey: .productType)
        vendor = try c.decodeIfPresent(String.self, forKey: .vendor)
        metafields = try c.decodeIfPresent([ShopifyMetafield].self, forKey: .metafields) ?? []
        images = try c.decodeIfPresent([ShopifyImage].self, forKey: .images) ?? []
    }

    public var isActive: Bool { status == "active" }

    public var lowestPrice: Double? {
        variants.compactMap { Double($0.price) }.min()
    }

    public var statusLabel: String {
        switch status {
        case "active":   return "En vente"
        case "draft":    return "Brouillon"
        case "archived": return "Archivé"
        default:         return status
        }
    }

    /// Individual tags, trimmed — see `tags` for why this isn't just `[String]`.
    public var tagList: [String] {
        tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

public struct ShopifyVariant: Codable, Sendable {
    public let id: Int
    public let price: String
    public let title: String
    public let sku: String?
    public let option1: String?
    public let option2: String?
    public let option3: String?
    public let compareAtPrice: String?

    public init(id: Int, price: String, title: String, sku: String? = nil,
                option1: String? = nil, option2: String? = nil, option3: String? = nil,
                compareAtPrice: String? = nil) {
        self.id = id
        self.price = price
        self.title = title
        self.sku = sku
        self.option1 = option1
        self.option2 = option2
        self.option3 = option3
        self.compareAtPrice = compareAtPrice
    }

    // Decode-only, matching Shopify's own snake_case wire format — kept
    // deliberately unnamed `CodingKeys` (see `ShopifyProduct.ShopifyWireKeys`
    // for why) so `encode(to:)` synthesizes separately with plain camelCase
    // keys for our own API's JSON, which is what the dashboard's JS reads.
    private enum ShopifyWireKeys: String, CodingKey {
        case id, price, title, sku, option1, option2, option3
        case compareAtPrice = "compare_at_price"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ShopifyWireKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        price = try c.decode(String.self, forKey: .price)
        title = try c.decode(String.self, forKey: .title)
        sku = try c.decodeIfPresent(String.self, forKey: .sku)
        option1 = try c.decodeIfPresent(String.self, forKey: .option1)
        option2 = try c.decodeIfPresent(String.self, forKey: .option2)
        option3 = try c.decodeIfPresent(String.self, forKey: .option3)
        compareAtPrice = try c.decodeIfPresent(String.self, forKey: .compareAtPrice)
    }
}

/// A product image, as returned in `products.json`'s `images` array — src is
/// a plain HTTPS URL Shopify hosts, no auth needed to fetch it.
public struct ShopifyImage: Codable, Sendable, Identifiable, Equatable {
    public let id: Int
    public let src: String
    public let alt: String?

    public init(id: Int, src: String, alt: String? = nil) {
        self.id = id
        self.src = src
        self.alt = alt
    }
}

/// A variant to set when creating a product — mirrors `ShopifyVariant` minus
/// the server-assigned `id`. Not setting `option1`/`option2`/`option3` (or the
/// product's own `options` list, which this client doesn't set at all) means
/// Shopify falls back to a single generic "Title" option using each variant's
/// `title` as its value — fine for the common case of a handful of named
/// variants without needing full Size/Color option metadata.
public struct ShopifyVariantInput: Codable, Sendable, Equatable {
    public var price: String
    public var title: String?
    public var sku: String?

    public init(price: String, title: String? = nil, sku: String? = nil) {
        self.price = price
        self.title = title
        self.sku = sku
    }
}

/// An image to attach when creating a product — Shopify accepts a base64
/// attachment directly in the product-creation payload, no separate upload
/// step. Used to carry a *project's* photos onto a duplicated product,
/// instead of the template product's own photos.
public struct ShopifyImageInput: Codable, Sendable {
    public var attachment: String
    public var filename: String?

    public init(attachment: String, filename: String? = nil) {
        self.attachment = attachment
        self.filename = filename
    }
}

/// A Shopify metafield (custom key/value data attached to a product — e.g. a
/// "matériau" or "temps d'impression" field set up in the Shopify admin).
/// `namespace`/`key` together identify it; `type` is Shopify's metafield type
/// (`single_line_text_field`, `number_integer`, `json`…) and is passed through
/// as-is rather than parsed, since it's only used for round-tripping so far.
public struct ShopifyMetafield: Codable, Sendable, Identifiable, Equatable {
    public let id: Int
    public let namespace: String
    public let key: String
    public let value: String
    public let type: String

    public init(id: Int, namespace: String, key: String, value: String, type: String) {
        self.id = id
        self.namespace = namespace
        self.key = key
        self.value = value
        self.type = type
    }
}

/// A metafield to set when creating a product (see `ShopifyClient.createProduct`)
/// — same shape as `ShopifyMetafield` minus the server-assigned `id`.
public struct ShopifyMetafieldInput: Codable, Sendable, Equatable {
    public var namespace: String
    public var key: String
    public var value: String
    public var type: String

    public init(namespace: String, key: String, value: String, type: String) {
        self.namespace = namespace
        self.key = key
        self.value = value
        self.type = type
    }
}

private struct ShopifyProductsResponse: Codable {
    let products: [ShopifyProduct]
}

private struct ShopifyMetafieldsResponse: Codable {
    let metafields: [ShopifyMetafield]
}

// MARK: - Product creation (duplicate-as-template)

private struct ShopifyProductCreateRequest: Codable {
    struct Variant: Codable { let price: String; let title: String?; let sku: String? }
    struct Metafield: Codable { let namespace: String; let key: String; let value: String; let type: String }
    struct Image: Codable { let attachment: String; let filename: String? }

    var title: String
    var status = "draft"
    var bodyHtml: String?
    var vendor: String?
    var productType: String?
    var tags: String?
    var variants: [Variant]?
    var metafields: [Metafield]?
    var images: [Image]?

    enum CodingKeys: String, CodingKey {
        case title, status, tags, vendor, variants, metafields, images
        case bodyHtml = "body_html"
        case productType = "product_type"
    }
}

private struct ShopifyProductCreateWrapper: Codable { let product: ShopifyProductCreateRequest }
private struct ShopifyProductCreateResponse: Codable { let product: ShopifyProduct }

// MARK: - Credentials

public struct ShopifyCredentials: Sendable {
    public var storeDomain: String
    /// Admin API access token (read_products scope).
    /// Create one in: Shopify Admin → Paramètres → Apps → Développer des apps.
    public var accessToken: String

    public init(storeDomain: String, accessToken: String) {
        self.storeDomain = storeDomain
        self.accessToken = accessToken
    }

    public var isConfigured: Bool {
        !storeDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var normalizedDomain: String {
        var d = storeDomain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !d.contains(".") { d += ".myshopify.com" }
        return d
    }
}

// MARK: - Shopify Client

/// Stateless client for the Shopify Admin API. Persistence of credentials and
/// caching of the product list are the caller's responsibility (server DB,
/// UserDefaults on the desktop app…).
public struct ShopifyClient: Sendable {
    public let credentials: ShopifyCredentials

    public init(credentials: ShopifyCredentials) {
        self.credentials = credentials
    }

    // MARK: - Sync

    /// Fetches all products from Shopify, handling cursor-based pagination, and
    /// attaches each product's metafields (a separate call per product — see
    /// `fetchMetafields`). Sequential, not concurrent: Shopify's REST rate limit
    /// is a 40-request leaky bucket refilling at 2 req/s, and this client has no
    /// 429 retry/backoff logic, so network round-trip latency alone keeps a
    /// sequential loop comfortably under that for realistic catalog sizes.
    /// A single product's metafields failing to fetch doesn't fail the whole
    /// sync — it's just left empty for that product.
    public func fetchAllProducts() async throws -> [ShopifyProduct] {
        guard credentials.isConfigured else { throw ShopifyError.notConfigured }

        var all: [ShopifyProduct] = []
        var cursor: String? = nil

        repeat {
            let (page, next) = try await fetchPage(pageInfo: cursor)
            all.append(contentsOf: page)
            cursor = next
        } while cursor != nil

        var withMetafields: [ShopifyProduct] = []
        withMetafields.reserveCapacity(all.count)
        for var product in all {
            product.metafields = (try? await fetchMetafields(productId: product.id)) ?? []
            withMetafields.append(product)
        }
        return withMetafields
    }

    /// Metafields aren't returned by `products.json` at any `fields=` setting —
    /// Shopify only exposes them via this dedicated per-product endpoint.
    public func fetchMetafields(productId: Int) async throws -> [ShopifyMetafield] {
        guard credentials.isConfigured else { throw ShopifyError.notConfigured }

        let url = URL(string: "https://\(credentials.normalizedDomain)/admin/api/2024-01/products/\(productId)/metafields.json")!
        var request = URLRequest(url: url)
        request.setValue(credentials.accessToken, forHTTPHeaderField: "X-Shopify-Access-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.portableData(for: request)
        guard let http = response as? HTTPURLResponse else { throw ShopifyError.invalidResponse }
        guard http.statusCode == 200 else { throw ShopifyError.httpError(http.statusCode) }

        return try JSONDecoder().decode(ShopifyMetafieldsResponse.self, from: data).metafields
    }

    /// Creates a new Shopify product from explicit field values — the caller
    /// (the web dashboard's "Dupliquer un produit" form) is responsible for
    /// pre-filling those from an existing product if it wants a duplicate;
    /// this function itself doesn't look anything up, so whatever's passed in
    /// is exactly what gets sent, edits included. Always created as a
    /// **draft** so a half-finished duplicate never goes live by accident —
    /// review and publish it from Shopify's own admin once it looks right.
    /// Requires the `write_products` Admin API scope (this client only needed
    /// `read_products` before now).
    public func createProduct(
        title: String,
        bodyHtml: String? = nil,
        vendor: String? = nil,
        productType: String? = nil,
        tags: String? = nil,
        variants: [ShopifyVariantInput] = [],
        metafields: [ShopifyMetafieldInput] = [],
        images: [ShopifyImageInput] = []
    ) async throws -> ShopifyProduct {
        guard credentials.isConfigured else { throw ShopifyError.notConfigured }

        var payload = ShopifyProductCreateRequest(title: title)
        payload.bodyHtml = bodyHtml
        payload.vendor = vendor
        payload.productType = productType
        payload.tags = (tags?.isEmpty ?? true) ? nil : tags
        if !variants.isEmpty {
            payload.variants = variants.map { .init(price: $0.price, title: $0.title, sku: $0.sku) }
        }
        if !metafields.isEmpty {
            payload.metafields = metafields.map {
                .init(namespace: $0.namespace, key: $0.key, value: $0.value, type: $0.type)
            }
        }
        if !images.isEmpty {
            payload.images = images.map { .init(attachment: $0.attachment, filename: $0.filename) }
        }

        let url = URL(string: "https://\(credentials.normalizedDomain)/admin/api/2024-01/products.json")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(credentials.accessToken, forHTTPHeaderField: "X-Shopify-Access-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ShopifyProductCreateWrapper(product: payload))
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.portableData(for: request)
        guard let http = response as? HTTPURLResponse else { throw ShopifyError.invalidResponse }
        guard http.statusCode == 200 || http.statusCode == 201 else { throw ShopifyError.httpError(http.statusCode) }

        return try JSONDecoder().decode(ShopifyProductCreateResponse.self, from: data).product
    }

    // MARK: - Matching

    /// Returns the Shopify product matching a project.
    /// Explicit ID assignment wins over fuzzy name matching.
    public static func matchProduct(in products: [ShopifyProduct],
                                    projectName: String,
                                    explicitProductId: String?) -> ShopifyProduct? {
        if let pid = explicitProductId, !pid.isEmpty,
           let idInt = Int(pid),
           let explicit = products.first(where: { $0.id == idInt }) {
            return explicit
        }
        // Fuzzy name match: product title contains project name or vice-versa
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return nil }
        return products.first { product in
            let title = product.title.lowercased()
            return title.contains(name) || name.contains(title)
        }
    }

    public func productURL(for product: ShopifyProduct) -> URL? {
        URL(string: "https://\(credentials.normalizedDomain)/products/\(product.handle)")
    }

    // MARK: - Private

    private func fetchPage(pageInfo: String?) async throws -> ([ShopifyProduct], next: String?) {
        var components = URLComponents(string: "https://\(credentials.normalizedDomain)/admin/api/2024-01/products.json")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "limit",  value: "250"),
            URLQueryItem(name: "fields", value: "id,title,status,handle,variants,body_html,tags,product_type,vendor,images"),
        ]
        if let pageInfo { items.append(URLQueryItem(name: "page_info", value: pageInfo)) }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.setValue(credentials.accessToken, forHTTPHeaderField: "X-Shopify-Access-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.portableData(for: request)

        guard let http = response as? HTTPURLResponse else { throw ShopifyError.invalidResponse }
        guard http.statusCode == 200 else { throw ShopifyError.httpError(http.statusCode) }

        let decoded = try JSONDecoder().decode(ShopifyProductsResponse.self, from: data)
        let next    = Self.parseLinkHeader(http.value(forHTTPHeaderField: "Link"))
        return (decoded.products, next)
    }

    /// Parses the Shopify `Link` header to extract the next-page cursor.
    /// Format: `<url?page_info=abc>; rel="next", <url?page_info=xyz>; rel="previous"`
    static func parseLinkHeader(_ header: String?) -> String? {
        guard let header else { return nil }
        for part in header.components(separatedBy: ",") {
            let segs = part.trimmingCharacters(in: .whitespaces).components(separatedBy: ";")
            guard segs.count >= 2,
                  segs[1].trimmingCharacters(in: .whitespaces) == "rel=\"next\"",
                  let url = URLComponents(string: segs[0]
                      .trimmingCharacters(in: .whitespaces)
                      .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))),
                  let cursor = url.queryItems?.first(where: { $0.name == "page_info" })?.value
            else { continue }
            return cursor
        }
        return nil
    }
}

// MARK: - Errors

public enum ShopifyError: LocalizedError {
    case notConfigured
    case invalidResponse
    case httpError(Int)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:       return "Credentials non configurés — renseignez l'URL de la boutique et le token d'accès"
        case .invalidResponse:     return "Réponse Shopify invalide"
        case .httpError(let code): return "Erreur HTTP \(code) — vérifiez vos credentials et l'URL de la boutique"
        }
    }
}

// MARK: - Linux URLSession shim
// swift-corelibs-foundation's async URLSession surface has lagged behind Darwin;
// route through a completion-handler bridge on non-Darwin platforms.

extension URLSession {
    func portableData(for request: URLRequest) async throws -> (Data, URLResponse) {
        #if canImport(FoundationNetworking)
        return try await withCheckedThrowingContinuation { continuation in
            let task = self.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
            task.resume()
        }
        #else
        return try await data(for: request)
        #endif
    }
}
