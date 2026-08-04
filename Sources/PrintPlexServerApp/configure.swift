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

    // Fluent's SQLite driver pools one connection *per event loop*, so a scan
    // writing to the database and a request reading from it usually end up on
    // different physical connections. Without WAL, SQLite's default rollback
    // journal takes a whole-file lock for every write transaction, so a long
    // scan (hundreds of sequential saves) starves every read for its entire
    // duration — this is exactly what made detail views hang on "Chargement"
    // while a scan was running. WAL lets readers proceed against a consistent
    // snapshot while a writer is active; busy_timeout is a defensive fallback
    // for the rarer writer-vs-writer case (e.g. a settings save landing in the
    // same instant as a scan write) so it retries briefly instead of erroring.
    if let sqlDb = app.db as? SQLDatabase {
        try await sqlDb.raw("PRAGMA journal_mode=WAL").run()
        try await sqlDb.raw("PRAGMA busy_timeout=5000").run()
    }

    app.migrations.add(CreateSchema())
    app.migrations.add(CreateSettingsSchema())
    app.migrations.add(CreateLibrariesSchema())
    app.migrations.add(AddPlateStatsToFiles())
    app.migrations.add(AddAlreadyPrintedToProjects())
    app.migrations.add(AddSourceInfoToProjects())
    try await app.autoMigrate()

    try await seedReferenceDataIfNeeded(app)

    app.scanService = ScanService(app: app, config: config)
    // Seeds the settings row from env vars on first boot; on later boots the
    // DB values (editable from the web Settings menu) take over.
    try await app.scanService.bootstrapSettings()

    if let settingsRow = try await AppSettingsModel.find(AppSettingsModel.singletonID, on: app.db) {
        let credentials = ShopifyCredentials(storeDomain: settingsRow.shopifyStoreDomain ?? "",
                                             accessToken: settingsRow.shopifyAccessToken ?? "")
        if credentials.isConfigured {
            let cache = ShopifyCache(credentials: credentials)
            app.shopifyCache = cache
            // `lastSyncDate` only ever lives in this actor's memory, so a fresh
            // process (e.g. `docker compose up --force-recreate`) always starts
            // with it nil, even though credentials were already saved — without
            // this, the dashboard shows nothing Shopify-related until someone
            // manually hits "Synchroniser" in Settings. Kicking a sync here
            // mirrors the scan-at-boot behavior below and needs to be
            // non-blocking: a slow/unreachable Shopify API shouldn't delay the
            // server from serving requests.
            if app.environment != .testing {
                Task.detached(priority: .background) {
                    try? await cache.sync()
                }
            }
        }
    }

    // Bind on all interfaces by default — the server is meant to run in Docker.
    app.http.server.configuration.hostname =
        Environment.get("PRINTPLEX_HOSTNAME") ?? "0.0.0.0"
    if let port = Environment.get("PRINTPLEX_PORT").flatMap(Int.init) {
        app.http.server.configuration.port = port
    }

    app.middleware.use(NoStoreAPIMiddleware())

    // Serves Public/ — the vanilla-JS test dashboard — with index.html at "/".
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory, defaultFile: "index.html"))

    try routes(app)

    // Boot scan + periodic rescan (no FSEvents on Linux; polling is the
    // pragmatic choice for Docker volumes anyway). Settings are re-read every
    // iteration so toggling auto-scan or changing the interval from the web
    // Settings menu takes effect without a restart.
    if app.environment != .testing {
        let scanService = app.scanService
        // Lowest Swift Concurrency priority: this loop should only make
        // progress opportunistically, never compete with request handling.
        Task.detached(priority: .background) {
            while !Task.isCancelled {
                let settings = await scanService.currentScanSettings()
                if settings.autoScanEnabled {
                    await scanService.runScan()
                    try? await Task.sleep(for: .seconds(settings.scanIntervalMinutes * 60))
                } else {
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
    }
}

/// Seeds the printers/materials tables from PrintPlexCore's built-in catalog
/// on first boot only — after that they're fully owned by the settings API.
private func seedReferenceDataIfNeeded(_ app: Application) async throws {
    if try await PrinterModel.query(on: app.db).count() == 0 {
        for (index, profile) in PrinterProfile.defaults.enumerated() {
            try await PrinterModel(from: profile, sortOrder: index).save(on: app.db)
        }
    }
    if try await MaterialModel.query(on: app.db).count() == 0 {
        for (index, material) in PrintMaterial.defaults.enumerated() {
            try await MaterialModel(from: material, sortOrder: index).save(on: app.db)
        }
    }
}
