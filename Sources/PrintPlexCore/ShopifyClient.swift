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
    /// Same story as `metafields` — not part of `products.json`, populated
    /// separately via `ShopifyClient.fetchCollects(productId:)` and merged in
    /// by `fetchAllProducts()`. Only *custom* (manually-curated) collections:
    /// smart/automated ones populate themselves from rules, so a product
    /// can't be manually added to one — there'd be nothing meaningful for
    /// product duplication to copy.
    public var collections: [ShopifyCollectionRef]
    /// Same story again — not part of `products.json` (REST doesn't expose
    /// Shopify's Standard Product Taxonomy Category at all), populated
    /// separately via `ShopifyClient.fetchCategory(productId:)`, which has
    /// to go through GraphQL. `nil` means "no category assigned", same as
    /// Shopify's own admin shows.
    public var category: ShopifyCategoryRef?

    public init(id: Int, title: String, status: String, handle: String, variants: [ShopifyVariant],
                bodyHtml: String? = nil, tags: String = "", productType: String? = nil,
                vendor: String? = nil, metafields: [ShopifyMetafield] = [],
                images: [ShopifyImage] = [], collections: [ShopifyCollectionRef] = [],
                category: ShopifyCategoryRef? = nil) {
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
        self.collections = collections
        self.category = category
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
        case id, title, status, handle, variants, tags, vendor, metafields, images, collections, category
        case bodyHtml = "body_html"
        case productType = "product_type"
    }

    // Custom decode: `metafields`/`collections`/`category` are never present
    // when decoding a `products.json` response (all fetched separately), and
    // the other new fields are defensively optional in case a future
    // `fields=` tweak omits one — same decodeIfPresent pattern as
    // PrinterProfile in PrintEstimator.swift.
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
        collections = try c.decodeIfPresent([ShopifyCollectionRef].self, forKey: .collections) ?? []
        category = try c.decodeIfPresent(ShopifyCategoryRef.self, forKey: .category)
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

    private enum CodingKeys: String, CodingKey { case id, namespace, key, value, type }

    /// Shopify's `value` is a plain string for most metafields, but at least
    /// `boolean`-typed ones come back as a raw JSON `true`/`false` instead of
    /// the string `"true"`/`"false"` — decode leniently and normalize
    /// whatever primitive shows up to a string, since every consumer here
    /// (the generic metadata editor, product duplication) treats metafield
    /// values as plain text regardless of `type`. Hit in practice: one
    /// mistyped boolean value was enough to fail decoding *every* metafield
    /// on that product, not just the one field.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        namespace = try c.decode(String.self, forKey: .namespace)
        key = try c.decode(String.self, forKey: .key)
        type = try c.decode(String.self, forKey: .type)
        if let stringValue = try? c.decode(String.self, forKey: .value) {
            value = stringValue
        } else if let boolValue = try? c.decode(Bool.self, forKey: .value) {
            value = boolValue ? "true" : "false"
        } else if let intValue = try? c.decode(Int.self, forKey: .value) {
            value = String(intValue)
        } else if let doubleValue = try? c.decode(Double.self, forKey: .value) {
            value = String(doubleValue)
        } else {
            value = ""
        }
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

/// A *custom* (manually-curated) collection — smart/automated collections
/// aren't represented by this type at all, since a product can't be
/// manually added to one (see `ShopifyClient.fetchCustomCollections`).
public struct ShopifyCollectionRef: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var title: String

    public init(id: Int, title: String) {
        self.id = id
        self.title = title
    }
}

/// A node from Shopify's Standard Product Taxonomy (e.g. "Apparel & Accessories
/// > Clothing > Costumes"). `id` is a taxonomy id (like
/// "gid://shopify/TaxonomyCategory/sg-4-17-2-17" or similar) — an opaque
/// string as far as this client is concerned, only ever round-tripped
/// between `fetchCategory` and `setCategory`, never parsed or constructed.
public struct ShopifyCategoryRef: Codable, Sendable, Equatable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

private struct ShopifyProductsResponse: Codable {
    let products: [ShopifyProduct]
}

private struct ShopifyMetafieldsResponse: Codable {
    let metafields: [ShopifyMetafield]
}

private struct ShopifyCustomCollectionsResponse: Codable {
    let customCollections: [ShopifyCollectionRef]
    enum CodingKeys: String, CodingKey { case customCollections = "custom_collections" }
}

private struct ShopifyCollectsResponse: Codable {
    let collects: [ShopifyCollect]
}

private struct ShopifyCollect: Codable {
    let collectionID: Int
    enum CodingKeys: String, CodingKey { case collectionID = "collection_id" }
}

private struct ShopifyCollectCreateWrapper: Codable {
    let collect: ShopifyCollectCreate
}

private struct ShopifyCollectCreate: Codable {
    let productID: Int
    let collectionID: Int
    enum CodingKeys: String, CodingKey {
        case productID = "product_id"
        case collectionID = "collection_id"
    }
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
    /// sync — it's just left empty for that product, but `onMetafieldsError`
    /// (if given) still hears about it — silently swallowing every failure
    /// here previously made a real permissions/scope problem indistinguishable
    /// from "this product genuinely has no metafields."
    public func fetchAllProducts(
        onMetafieldsError: (@Sendable (_ productId: Int, _ error: Error) -> Void)? = nil
    ) async throws -> [ShopifyProduct] {
        guard credentials.isConfigured else { throw ShopifyError.notConfigured }

        var all: [ShopifyProduct] = []
        var cursor: String? = nil

        repeat {
            let (page, next) = try await fetchPage(pageInfo: cursor)
            all.append(contentsOf: page)
            cursor = next
        } while cursor != nil

        // Fetched once up-front (not per product) — collects only carry a
        // collection *id*, this is what turns that into a name, and doubles
        // as the "is this actually a custom collection?" filter (a collect
        // pointing at an id absent here is a smart collection, silently
        // excluded — see `ShopifyCollectionRef`).
        var customCollectionsByID: [Int: String] = [:]
        do {
            for collection in try await fetchCustomCollections() {
                customCollectionsByID[collection.id] = collection.title
            }
        } catch {
            onMetafieldsError?(-1, error)
        }

        var withMetafields: [ShopifyProduct] = []
        withMetafields.reserveCapacity(all.count)
        for var product in all {
            do {
                product.metafields = try await fetchMetafields(productId: product.id)
            } catch {
                onMetafieldsError?(product.id, error)
                product.metafields = []
            }
            do {
                let collectionIDs = try await fetchCollects(productId: product.id)
                product.collections = collectionIDs.compactMap { id in
                    customCollectionsByID[id].map { ShopifyCollectionRef(id: id, title: $0) }
                }
            } catch {
                onMetafieldsError?(product.id, error)
                product.collections = []
            }
            do {
                product.category = try await fetchCategory(productId: product.id)
            } catch {
                onMetafieldsError?(product.id, error)
                product.category = nil
            }
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

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.portableData(for: request)
        } catch {
            throw ShopifyError.wrapNetworkError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ShopifyError.invalidResponse }
        guard http.statusCode == 200 else {
            throw ShopifyError.httpError(status: http.statusCode, detail: ShopifyError.errorDetail(from: data))
        }

        return try JSONDecoder().decode(ShopifyMetafieldsResponse.self, from: data).metafields
    }

    /// Every *custom* collection in the store — smart/automated ones are
    /// excluded at the source, by construction: they only show up via
    /// `/smart_collections.json`, a different endpoint this never calls.
    /// One page (up to 250) — the practical ceiling for how many manually-
    /// curated collections a store built by one or two people tends to have.
    public func fetchCustomCollections() async throws -> [ShopifyCollectionRef] {
        guard credentials.isConfigured else { throw ShopifyError.notConfigured }

        let url = URL(string: "https://\(credentials.normalizedDomain)/admin/api/2024-01/custom_collections.json?limit=250&fields=id,title")!
        var request = URLRequest(url: url)
        request.setValue(credentials.accessToken, forHTTPHeaderField: "X-Shopify-Access-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.portableData(for: request)
        } catch {
            throw ShopifyError.wrapNetworkError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ShopifyError.invalidResponse }
        guard http.statusCode == 200 else {
            throw ShopifyError.httpError(status: http.statusCode, detail: ShopifyError.errorDetail(from: data))
        }
        return try JSONDecoder().decode(ShopifyCustomCollectionsResponse.self, from: data).customCollections
    }

    /// Which collections (by id — custom *and* smart) a product currently
    /// belongs to. Collects aren't part of `products.json` at any `fields=`
    /// setting, same story as metafields.
    public func fetchCollects(productId: Int) async throws -> [Int] {
        guard credentials.isConfigured else { throw ShopifyError.notConfigured }

        let url = URL(string: "https://\(credentials.normalizedDomain)/admin/api/2024-01/collects.json?product_id=\(productId)&limit=250&fields=collection_id")!
        var request = URLRequest(url: url)
        request.setValue(credentials.accessToken, forHTTPHeaderField: "X-Shopify-Access-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.portableData(for: request)
        } catch {
            throw ShopifyError.wrapNetworkError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ShopifyError.invalidResponse }
        guard http.statusCode == 200 else {
            throw ShopifyError.httpError(status: http.statusCode, detail: ShopifyError.errorDetail(from: data))
        }
        return try JSONDecoder().decode(ShopifyCollectsResponse.self, from: data).collects.map(\.collectionID)
    }

    /// Adds a product to a *custom* collection — the only kind this is even
    /// possible for; a smart collection populates itself from its own rules.
    public func addToCollection(productId: Int, collectionId: Int) async throws {
        guard credentials.isConfigured else { throw ShopifyError.notConfigured }

        let url = URL(string: "https://\(credentials.normalizedDomain)/admin/api/2024-01/collects.json")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(credentials.accessToken, forHTTPHeaderField: "X-Shopify-Access-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(
            ShopifyCollectCreateWrapper(collect: .init(productID: productId, collectionID: collectionId))
        )

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.portableData(for: request)
        } catch {
            throw ShopifyError.wrapNetworkError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ShopifyError.invalidResponse }
        guard http.statusCode == 200 || http.statusCode == 201 else {
            throw ShopifyError.httpError(status: http.statusCode, detail: ShopifyError.errorDetail(from: data))
        }
    }

    // MARK: - GraphQL (Category)
    //
    // Shopify's Standard Product Taxonomy Category has no REST representation
    // at all, read or write — the *only* way to see or set what category a
    // product belongs to is the Admin GraphQL API. Everything else this
    // client does stays REST; this is the one exception, kept as small as
    // possible: one query, one mutation, both going through `graphQL(...)`.

    private struct GraphQLRequestBody<Variables: Encodable>: Encodable {
        let query: String
        let variables: Variables
    }

    private struct GraphQLResponseBody<ResponseData: Decodable>: Decodable {
        let data: ResponseData?
        let errors: [GraphQLTopLevelError]?
    }

    private struct GraphQLTopLevelError: Decodable {
        let message: String
    }

    private struct GraphQLUserError: Decodable {
        let field: [String]?
        let message: String
    }

    /// POSTs one GraphQL operation and unwraps its `data`, surfacing either a
    /// top-level `errors` entry (malformed query, wrong scope, etc.) as
    /// `ShopifyError.graphQLError` — mutation-specific `userErrors` (e.g. an
    /// invalid category id) aren't caught here, since those live *inside*
    /// `data` in a shape specific to each mutation; callers check those
    /// themselves (see `setCategory`/`setShopifyMetafields`).
    private func graphQL<Variables: Encodable, ResponseData: Decodable>(
        query: String, variables: Variables, responseType: ResponseData.Type
    ) async throws -> ResponseData {
        guard credentials.isConfigured else { throw ShopifyError.notConfigured }

        let url = URL(string: "https://\(credentials.normalizedDomain)/admin/api/2024-01/graphql.json")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(credentials.accessToken, forHTTPHeaderField: "X-Shopify-Access-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(GraphQLRequestBody(query: query, variables: variables))

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.portableData(for: request)
        } catch {
            throw ShopifyError.wrapNetworkError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ShopifyError.invalidResponse }
        guard http.statusCode == 200 else {
            throw ShopifyError.httpError(status: http.statusCode, detail: ShopifyError.errorDetail(from: data))
        }

        let decoded = try JSONDecoder().decode(GraphQLResponseBody<ResponseData>.self, from: data)
        if let errors = decoded.errors, !errors.isEmpty {
            throw ShopifyError.graphQLError(errors.map(\.message).joined(separator: " ; "))
        }
        guard let responseData = decoded.data else { throw ShopifyError.invalidResponse }
        return responseData
    }

    private struct ProductCategoryQuery: Decodable {
        struct ProductNode: Decodable {
            let category: ShopifyCategoryRef?
        }
        let product: ProductNode?
    }

    /// The template product's assigned Category, if any — `nil` if it has
    /// none (perfectly normal; category assignment is optional on Shopify).
    public func fetchCategory(productId: Int) async throws -> ShopifyCategoryRef? {
        struct Variables: Encodable { let id: String }
        let query = """
        query($id: ID!) {
          product(id: $id) {
            category { id name }
          }
        }
        """
        let result = try await graphQL(
            query: query,
            variables: Variables(id: "gid://shopify/Product/\(productId)"),
            responseType: ProductCategoryQuery.self
        )
        return result.product?.category
    }

    private struct ProductUpdatePayload: Decodable {
        let productUpdate: Payload?
        struct Payload: Decodable { let userErrors: [GraphQLUserError] }
    }

    /// Assigns a Category to a product — always a *separate* call from
    /// creating the product (REST) or setting its other metafields, so a
    /// rejected category (a stale id, a category Shopify has since retired)
    /// only ever costs the category itself, never the product or its other
    /// data. `userErrors` (e.g. "Category can't be blank" for a bad id) are
    /// GraphQL's own per-field validation, distinct from a transport-level
    /// failure — surfaced the same way, since either one means "the category
    /// didn't get set."
    public func setCategory(productId: Int, categoryId: String) async throws {
        struct Variables: Encodable {
            struct Input: Encodable { let id: String; let category: String }
            let input: Input
        }
        let mutation = """
        mutation($input: ProductInput!) {
          productUpdate(input: $input) {
            userErrors { field message }
          }
        }
        """
        let result = try await graphQL(
            query: mutation,
            variables: Variables(input: .init(id: "gid://shopify/Product/\(productId)", category: categoryId)),
            responseType: ProductUpdatePayload.self
        )
        if let errors = result.productUpdate?.userErrors, !errors.isEmpty {
            throw ShopifyError.graphQLError(errors.map(\.message).joined(separator: " ; "))
        }
    }

    /// Sets metafields in Shopify's reserved `shopify` namespace (target
    /// gender, age group, and anything else category-scoped the template
    /// had) — kept as its own call, made only *after* `setCategory` already
    /// succeeded, since these fields are only valid once a category backs
    /// them; bundling them into the same request as category assignment (or
    /// worse, the product's initial creation) is exactly what caused every
    /// one of these fields to make the *entire* product creation fail with a
    /// cryptic "Owner subtype does not match the metafield definition's
    /// constraints" before this was pulled out into its own isolated step.
    public func setShopifyMetafields(productId: Int, metafields: [ShopifyMetafieldInput]) async throws {
        guard !metafields.isEmpty else { return }
        struct Variables: Encodable {
            struct Input: Encodable { let id: String; let metafields: [MetafieldInput] }
            struct MetafieldInput: Encodable { let namespace: String; let key: String; let value: String; let type: String }
            let input: Input
        }
        let mutation = """
        mutation($input: ProductInput!) {
          productUpdate(input: $input) {
            userErrors { field message }
          }
        }
        """
        let input = Variables.Input(
            id: "gid://shopify/Product/\(productId)",
            metafields: metafields.map { .init(namespace: $0.namespace, key: $0.key, value: $0.value, type: $0.type) }
        )
        let result = try await graphQL(
            query: mutation, variables: Variables(input: input), responseType: ProductUpdatePayload.self
        )
        if let errors = result.productUpdate?.userErrors, !errors.isEmpty {
            throw ShopifyError.graphQLError(errors.map(\.message).joined(separator: " ; "))
        }
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
    ///
    /// `collections` are applied *after* the product itself is created, one
    /// `addToCollection` call each — a failure partway through (a stale id,
    /// a transient error) doesn't undo or fail the product creation, it's
    /// just reported via `onCollectionError` the same way a metafields fetch
    /// failure is during sync, and the rest are still attempted. Takes
    /// `ShopifyCollectionRef` rather than bare ids so the returned product
    /// can echo back real titles immediately, without waiting on the next
    /// full sync to look them up.
    public func createProduct(
        title: String,
        bodyHtml: String? = nil,
        vendor: String? = nil,
        productType: String? = nil,
        tags: String? = nil,
        variants: [ShopifyVariantInput] = [],
        metafields: [ShopifyMetafieldInput] = [],
        images: [ShopifyImageInput] = [],
        collections: [ShopifyCollectionRef] = [],
        category: ShopifyCategoryRef? = nil,
        categoryMetafields: [ShopifyMetafieldInput] = [],
        onCollectionError: (@Sendable (_ collectionId: Int, _ error: Error) -> Void)? = nil,
        onCategoryError: (@Sendable (_ stage: String, _ error: Error) -> Void)? = nil
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
        // Longer than the other calls here: when `images` carries base64
        // photo attachments, Shopify has to fetch/decode/store each one
        // itself before responding, and 30s turned out to not always be
        // enough for that — a real timeout here previously surfaced as a
        // raw, unhelpful `NSURLErrorDomain Code=-1001` string.
        request.timeoutInterval = images.isEmpty ? 30 : 120

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.portableData(for: request)
        } catch {
            throw ShopifyError.wrapNetworkError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ShopifyError.invalidResponse }
        guard http.statusCode == 200 || http.statusCode == 201 else {
            throw ShopifyError.httpError(status: http.statusCode, detail: ShopifyError.errorDetail(from: data))
        }

        var created = try JSONDecoder().decode(ShopifyProductCreateResponse.self, from: data).product

        var attached: [ShopifyCollectionRef] = []
        for collection in collections {
            do {
                try await addToCollection(productId: created.id, collectionId: collection.id)
                attached.append(collection)
            } catch {
                onCollectionError?(collection.id, error)
            }
        }
        created.collections = attached

        // Category, then (only if that actually succeeded) its metafields —
        // never bundled with each other or with the product creation above.
        // See `setShopifyMetafields` for why that isolation matters.
        if let category {
            do {
                try await setCategory(productId: created.id, categoryId: category.id)
                created.category = category
                if !categoryMetafields.isEmpty {
                    do {
                        try await setShopifyMetafields(productId: created.id, metafields: categoryMetafields)
                    } catch {
                        onCategoryError?("category metafields", error)
                    }
                }
            } catch {
                onCategoryError?("category", error)
            }
        }
        return created
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

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.portableData(for: request)
        } catch {
            throw ShopifyError.wrapNetworkError(error)
        }

        guard let http = response as? HTTPURLResponse else { throw ShopifyError.invalidResponse }
        guard http.statusCode == 200 else {
            throw ShopifyError.httpError(status: http.statusCode, detail: ShopifyError.errorDetail(from: data))
        }

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
    case httpError(status: Int, detail: String?)
    /// The request never got an HTTP response at all — timeout, DNS failure,
    /// connection reset. Stores only a description (not the underlying
    /// `Error`) to stay `Sendable`; the message is computed once at the
    /// throw site where the concrete error type is still known.
    case networkError(String)
    /// A GraphQL call got a normal 200 OK, but the response's own `errors`
    /// array (query-level) or a mutation payload's `userErrors` (e.g.
    /// `productUpdate`) reported a problem — GraphQL doesn't use HTTP status
    /// codes for this the way REST does.
    case graphQLError(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Credentials non configurés — renseignez l'URL de la boutique et le token d'accès"
        case .invalidResponse:
            return "Réponse Shopify invalide"
        case .networkError(let detail):
            return "Erreur réseau vers Shopify : \(detail)"
        case .graphQLError(let detail):
            return "Erreur Shopify (GraphQL) : \(detail)"
        case .httpError(let status, let detail):
            // A bare status code alone actively misled here: 401/403/404 really
            // are a credentials/URL problem, but 422 means Shopify *understood*
            // the request and rejected its *content* (a validation error) —
            // the previous one-size-fits-all message told users to re-check
            // credentials for a problem that had nothing to do with them.
            let hint: String
            switch status {
            case 401, 403: hint = "vérifiez vos credentials (token / scope)"
            case 404:      hint = "vérifiez l'URL de la boutique"
            case 422:      hint = "la requête a été rejetée (données invalides)"
            default:       hint = "vérifiez vos credentials et l'URL de la boutique"
            }
            let suffix = detail.map { " — \($0)" } ?? ""
            return "Erreur HTTP \(status) — \(hint)\(suffix)"
        }
    }

    /// Best-effort extraction of Shopify's own error message from a non-2xx
    /// response body, so failures actually say what Shopify rejected instead
    /// of just a status code. Shopify's `errors` field is either a plain
    /// string or a `{field: [messages]}` object depending on the endpoint —
    /// falls back to the first line of the raw body if neither shape parses.
    static func errorDetail(from data: Data) -> String? {
        struct StringErrors: Decodable { let errors: String }
        struct FieldErrors: Decodable { let errors: [String: [String]] }

        if let parsed = try? JSONDecoder().decode(StringErrors.self, from: data) {
            return parsed.errors
        }
        if let parsed = try? JSONDecoder().decode(FieldErrors.self, from: data) {
            return parsed.errors.map { field, messages in "\(field): \(messages.joined(separator: ", "))" }
                .sorted().joined(separator: " ; ")
        }
        guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return String(raw.prefix(300))
    }

    /// Wraps whatever `URLSession` throws before an HTTP response even comes
    /// back (timeout, DNS failure, connection reset) into a `.networkError`
    /// with a message worth reading — a raw `NSURLErrorDomain Code=-1001
    /// "(null)"` reaching the dashboard verbatim isn't useful to anyone.
    static func wrapNetworkError(_ error: Error) -> ShopifyError {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return .networkError("délai d'attente dépassé — réessayez, ou réduisez le nombre/la taille des photos jointes si vous en avez ajouté")
        }
        return .networkError(error.localizedDescription)
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
