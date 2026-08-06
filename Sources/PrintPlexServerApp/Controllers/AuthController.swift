import Vapor
import Fluent
import Foundation

struct AuthStatusResponse: Content {
    var setupRequired: Bool
    var authenticated: Bool
}

struct AuthCredentialsRequest: Content {
    var username: String
    var password: String
}

struct AuthAccountResponse: Content {
    var username: String
}

struct ChangePasswordRequest: Content {
    var currentPassword: String
    var newPassword: String
}

struct ApiKeyResponse: Content {
    var apiKey: String
}

/// Single-admin-account auth for the web dashboard: a classic username/
/// password login (session-cookie based, via `AuthMiddleware`) plus a
/// separate API key for services that can't do a browser login — the
/// ForgeCore relay, the native client. Both live on the same `app_settings`
/// singleton row as everything else in Réglages.
struct AuthController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let auth = routes.grouped("api", "auth")
        auth.get("status", use: status)
        auth.post("setup", use: setup)
        auth.post("login", use: login)
        auth.post("logout", use: logout)
        auth.post("change-password", use: changePassword)
        auth.get("api-key", use: apiKey)
        auth.post("api-key", "regenerate", use: regenerateApiKey)
    }

    @Sendable
    func status(req: Request) async throws -> AuthStatusResponse {
        let row = try await settingsRow(req)
        return AuthStatusResponse(
            setupRequired: (row.adminUsername ?? "").isEmpty,
            authenticated: req.isAuthenticated
        )
    }

    /// Only works while no admin account exists yet — the very first "log
    /// in" a fresh server ever gets. Once an account exists this always
    /// 403s, so a stray unauthenticated request can never use it to add a
    /// second account.
    @Sendable
    func setup(req: Request) async throws -> AuthAccountResponse {
        let body = try req.content.decode(AuthCredentialsRequest.self)
        let row = try await settingsRow(req)
        guard (row.adminUsername ?? "").isEmpty else {
            throw Abort(.forbidden, reason: "Un compte administrateur existe déjà")
        }
        try Self.applyCredentials(username: body.username, password: body.password, to: row)
        if row.apiKey == nil { row.apiKey = Self.generateAPIKey() }
        try await row.save(on: req.db)
        req.isAuthenticated = true
        return AuthAccountResponse(username: row.adminUsername ?? "")
    }

    @Sendable
    func login(req: Request) async throws -> AuthAccountResponse {
        let body = try req.content.decode(AuthCredentialsRequest.self)
        let row = try await settingsRow(req)
        guard let username = row.adminUsername, let hash = row.adminPasswordHash,
              username == body.username, try Bcrypt.verify(body.password, created: hash)
        else {
            throw Abort(.unauthorized, reason: "Identifiants invalides")
        }
        req.isAuthenticated = true
        return AuthAccountResponse(username: username)
    }

    @Sendable
    func logout(req: Request) async throws -> HTTPStatus {
        req.session.destroy()
        return .ok
    }

    @Sendable
    func changePassword(req: Request) async throws -> HTTPStatus {
        guard req.isAuthenticated else { throw Abort(.unauthorized) }
        let body = try req.content.decode(ChangePasswordRequest.self)
        let row = try await settingsRow(req)
        guard let hash = row.adminPasswordHash,
              try Bcrypt.verify(body.currentPassword, created: hash)
        else {
            throw Abort(.unauthorized, reason: "Mot de passe actuel incorrect")
        }
        guard body.newPassword.count >= 8 else {
            throw Abort(.badRequest, reason: "Le nouveau mot de passe doit faire au moins 8 caractères")
        }
        row.adminPasswordHash = try Bcrypt.hash(body.newPassword)
        try await row.save(on: req.db)
        return .ok
    }

    /// Includes the plaintext key so it can be copied into another service's
    /// config — same trust model as the Shopify access token in Réglages.
    @Sendable
    func apiKey(req: Request) async throws -> ApiKeyResponse {
        guard req.isAuthenticated else { throw Abort(.unauthorized) }
        let row = try await settingsRow(req)
        if row.apiKey == nil {
            row.apiKey = Self.generateAPIKey()
            try await row.save(on: req.db)
        }
        return ApiKeyResponse(apiKey: row.apiKey ?? "")
    }

    @Sendable
    func regenerateApiKey(req: Request) async throws -> ApiKeyResponse {
        guard req.isAuthenticated else { throw Abort(.unauthorized) }
        let row = try await settingsRow(req)
        row.apiKey = Self.generateAPIKey()
        try await row.save(on: req.db)
        return ApiKeyResponse(apiKey: row.apiKey ?? "")
    }

    private func settingsRow(_ req: Request) async throws -> AppSettingsModel {
        guard let row = try await AppSettingsModel.find(AppSettingsModel.singletonID, on: req.db) else {
            throw Abort(.internalServerError, reason: "Ligne de réglages absente")
        }
        return row
    }

    static func applyCredentials(username: String, password: String, to row: AppSettingsModel) throws {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            throw Abort(.badRequest, reason: "Le nom d'utilisateur est obligatoire")
        }
        guard password.count >= 8 else {
            throw Abort(.badRequest, reason: "Le mot de passe doit faire au moins 8 caractères")
        }
        row.adminUsername = trimmedUsername
        row.adminPasswordHash = try Bcrypt.hash(password)
    }

    /// `UInt8.random` draws from Swift's `SystemRandomNumberGenerator`
    /// (`getrandom`/`arc4random` under the hood) — cryptographically fine
    /// without pulling in a dedicated crypto dependency for one call site.
    static func generateAPIKey() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "=", with: "")
        return "ppx_" + encoded
    }

    /// Seeds the admin account from env vars on first boot only — after that
    /// it's fully owned by the DB row (editable from Réglages, like every
    /// other credential here). Mirrors `AppSettingsModel.loadOrCreate`'s
    /// Shopify-credential seeding, just kept separate since it needs Bcrypt.
    static func seedFromEnvironmentIfNeeded(_ app: Application) async throws {
        guard let username = Environment.get("PRINTPLEX_ADMIN_USERNAME")?
                .trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty,
              let password = Environment.get("PRINTPLEX_ADMIN_PASSWORD"), !password.isEmpty
        else { return }
        guard let row = try await AppSettingsModel.find(AppSettingsModel.singletonID, on: app.db),
              (row.adminUsername ?? "").isEmpty
        else { return }
        try applyCredentials(username: username, password: password, to: row)
        if row.apiKey == nil { row.apiKey = generateAPIKey() }
        try await row.save(on: app.db)
    }
}

extension Request {
    var isAuthenticated: Bool {
        get { session.data["authenticated"] == "true" }
        set { session.data["authenticated"] = newValue ? "true" : nil }
    }
}
