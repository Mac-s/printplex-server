import Vapor
import PrintPlexCore

struct HealthResponse: Content {
    var status: String
    var mediaPath: String
}

func routes(_ app: Application) throws {
    app.get("health") { req async throws -> HealthResponse in
        HealthResponse(status: "ok", mediaPath: req.application.appConfig.mediaPath)
    }

    try app.register(collection: AuthController())
    try app.register(collection: ProjectController())
    try app.register(collection: FileController())
    try app.register(collection: ScanController())
    try app.register(collection: ShopifyController())
    try app.register(collection: PrinterController())
    try app.register(collection: MaterialController())
    try app.register(collection: SettingsController())
    try app.register(collection: LibraryController())
    try app.register(collection: ForgeCoreController())
}
