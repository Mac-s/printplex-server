import Vapor
import Fluent
import FluentSQLiteDriver
import PrintPlexCore

func configure(_ app: Application) async throws {
    let config = AppConfig.fromEnvironment()
    app.appConfig = config

    try FileManager.default.createDirectory(
        atPath: config.dataPath, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        atPath: config.thumbnailsPath, withIntermediateDirectories: true)

    app.databases.use(
        .sqlite(config.inMemoryDatabase ? .memory : .file(config.databasePath)),
        as: .sqlite
    )
    app.migrations.add(CreateSchema())
    try await app.autoMigrate()

    app.scanService = ScanService(app: app, config: config)
    if let credentials = config.shopifyCredentials {
        app.shopifyCache = ShopifyCache(credentials: credentials)
    }

    // Bind on all interfaces by default — the server is meant to run in Docker.
    app.http.server.configuration.hostname =
        Environment.get("PRINTPLEX_HOSTNAME") ?? "0.0.0.0"
    if let port = Environment.get("PRINTPLEX_PORT").flatMap(Int.init) {
        app.http.server.configuration.port = port
    }

    try routes(app)

    // Boot scan + periodic rescan (no FSEvents on Linux; polling is the
    // pragmatic choice for Docker volumes anyway).
    if config.scanIntervalMinutes > 0, app.environment != .testing {
        let scanService = app.scanService
        let interval = Duration.seconds(config.scanIntervalMinutes * 60)
        Task.detached {
            await scanService.runScan()
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await scanService.runScan()
            }
        }
    }
}
