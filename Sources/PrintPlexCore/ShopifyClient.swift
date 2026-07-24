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

    public init(id: Int, title: String, status: String, handle: String, variants: [ShopifyVariant]) {
        self.id = id
        self.title = title
        self.status = status
        self.handle = handle
        self.variants = variants
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
}

public struct ShopifyVariant: Codable, Sendable {
    public let id: Int
    public let price: String
    public let title: String

    public init(id: Int, price: String, title: String) {
        self.id = id
        self.price = price
        self.title = title
    }
}

private struct ShopifyProductsResponse: Codable {
    let products: [ShopifyProduct]
}

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

    /// Fetches all products from Shopify, handling cursor-based pagination.
    public func fetchAllProducts() async throws -> [ShopifyProduct] {
        guard credentials.isConfigured else { throw ShopifyError.notConfigured }

        var all: [ShopifyProduct] = []
        var cursor: String? = nil

        repeat {
            let (page, next) = try await fetchPage(pageInfo: cursor)
            all.append(contentsOf: page)
            cursor = next
        } while cursor != nil

        return all
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
            URLQueryItem(name: "fields", value: "id,title,status,handle,variants"),
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
