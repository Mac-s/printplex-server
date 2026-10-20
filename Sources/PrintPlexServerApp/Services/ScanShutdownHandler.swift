import Vapor

/// Lets a scan that is already running finish — and stops new ones from
/// starting — before Vapor tears the database and storage down.
struct ScanShutdownHandler: LifecycleHandler {
    func shutdownAsync(_ app: Application) async {
        await app.scanService.shutdown()
    }
}
