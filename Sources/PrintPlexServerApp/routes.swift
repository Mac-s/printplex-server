import Vapor
import PrintPlexCore

struct HealthResponse: Content {
    var status: String
    var libraryPath: String
}

func routes(_ app: Application) throws {
    app.get("health") { req async throws -> HealthResponse in
        HealthResponse(status: "ok", libraryPath: req.application.appConfig.libraryPath)
    }

    // Reference data for estimate parameters (defaults for now;
    // per-user profiles become DB-backed in a later phase).
    app.get("api", "printers") { _ async -> [PrinterProfile] in
        PrinterProfile.defaults
    }
    app.get("api", "materials") { _ async -> [PrintMaterial] in
        PrintMaterial.defaults
    }

    try app.register(collection: ProjectController())
    try app.register(collection: FileController())
    try app.register(collection: ScanController())
    try app.register(collection: ShopifyController())
}
