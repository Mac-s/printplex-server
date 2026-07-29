import Vapor

/// Every `/api/*` response reflects live, frequently-changing server state
/// (projects, files, Shopify sync…) — the browser must never reuse a cached
/// copy of one, unlike the static dashboard assets under `Public/` (which
/// intentionally *do* cache, hence the occasional need for a hard refresh
/// after deploying a JS/CSS change).
///
/// Concretely hit in practice: without this, a browser kept serving a
/// long-stale cached `/api/shopify/products` response missing `bodyHtml`/
/// `productType` (added later) even though the server had been returning
/// them correctly for a while — nothing server-side was wrong, the browser
/// just never re-fetched. Vapor sets no cache headers on JSON `Content`
/// responses by default, leaving that entirely up to browser heuristics.
struct NoStoreAPIMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        if request.url.path.hasPrefix("/api/") {
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        }
        return response
    }
}
