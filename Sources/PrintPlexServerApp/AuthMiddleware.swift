import Vapor
import Fluent

/// Gates every `/api/*` route except the auth endpoints themselves (login
/// has to stay reachable while logged out, obviously) behind either a
/// logged-in browser session or an `X-API-Key` header — the latter is what
/// lets other services (the ForgeCore relay, the native client) call the API
/// without a cookie-based login. Static assets under `Public/` and `/health`
/// are untouched — no secrets live there.
struct AuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard request.application.authEnforcementEnabled else {
            return try await next.respond(to: request)
        }
        let path = request.url.path
        guard path.hasPrefix("/api/"), !path.hasPrefix("/api/auth/") else {
            return try await next.respond(to: request)
        }
        if request.isAuthenticated {
            return try await next.respond(to: request)
        }
        // Query-param fallback exists for SwiftUI's `AsyncImage(url:)`, which
        // has no way to attach a header — thumbnails/gallery images in the
        // native client go through this, not the header.
        let providedKey = request.headers.first(name: "X-API-Key")
            ?? request.query[String.self, at: "api_key"]
        if let providedKey, !providedKey.isEmpty,
           let row = try await AppSettingsModel.find(AppSettingsModel.singletonID, on: request.db),
           let apiKey = row.apiKey, !apiKey.isEmpty, providedKey == apiKey {
            return try await next.respond(to: request)
        }
        throw Abort(.unauthorized, reason: "Authentification requise")
    }
}

struct AuthEnforcementOverrideKey: StorageKey { typealias Value = Bool }

extension Application {
    /// Auth is enforced by default everywhere except `.testing` — the
    /// existing test suites (`ServerTests`, `SettingsTests`, `LibraryTests`,
    /// 120+ call sites) predate this feature and call the API directly with
    /// no session/API key, so gating them by default would break all of
    /// them for no real coverage gain. `AuthTests` sets this to `true`
    /// explicitly to exercise the real gating end-to-end.
    var authEnforcementEnabled: Bool {
        get { storage[AuthEnforcementOverrideKey.self] ?? (environment != .testing) }
        set { storage[AuthEnforcementOverrideKey.self] = newValue }
    }
}
