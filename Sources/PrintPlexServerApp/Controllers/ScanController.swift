import Vapor
import Fluent

struct ScanStatusResponse: Content {
    var isScanning: Bool
    var lastScanDate: Date?
    var lastScanProjects: Int
    var lastScanFiles: Int
    var projectCount: Int
    var fileCount: Int
}

struct ScanController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let scan = routes.grouped("api", "scan")
        scan.post(use: trigger)
        scan.get("status", use: status)
        scan.get("events", use: events)
    }

    /// POST /api/scan — background by default; ?wait=true blocks until done
    /// (scan + mesh parsing), which is also what the tests rely on.
    @Sendable
    func trigger(req: Request) async throws -> ScanStatusResponse {
        let service = req.application.scanService
        let wait = (try? req.query.get(Bool.self, at: "wait")) ?? false
        if wait {
            // Caller explicitly asked to block until done — run at normal
            // priority so it doesn't sit needlessly behind other background work.
            await service.runScan()
        } else {
            // Fire-and-forget: this is exactly the kind of work that should
            // yield to anything request-driven, so it runs at the lowest priority.
            Task.detached(priority: .background) { await service.runScan() }
        }
        return try await makeStatus(req)
    }

    @Sendable
    func status(req: Request) async throws -> ScanStatusResponse {
        try await makeStatus(req)
    }

    /// GET /api/scan/events — Server-Sent Events stream of scan progress.
    @Sendable
    func events(req: Request) async throws -> Response {
        let service = req.application.scanService
        let stream = await service.subscribe()

        let response = Response(status: .ok)
        response.headers.replaceOrAdd(name: .contentType, value: "text/event-stream")
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        response.headers.replaceOrAdd(name: .connection, value: "keep-alive")
        // Vapor's asyncStream body REQUIRES the closure to call .end or .error
        // before returning, in every case — including when the client
        // disconnects mid-stream (writer.write then throws a broken-pipe
        // error). Letting that propagate uncaught doesn't just fail the
        // request, it trips a fatal assertion and takes down the whole
        // process. Every exit path below is funneled through .end/.error.
        response.body = .init(asyncStream: { writer in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                for await event in stream {
                    guard let data = try? encoder.encode(event) else { continue }
                    let line = "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
                    try await writer.write(.buffer(ByteBuffer(string: line)))
                }
                try await writer.write(.end)
            } catch {
                try? await writer.write(.error(error))
            }
        })
        return response
    }

    private func makeStatus(_ req: Request) async throws -> ScanStatusResponse {
        let state = await req.application.scanService.state()
        let projectCount = try await ProjectModel.query(on: req.db).count()
        let fileCount = try await FileModel.query(on: req.db).count()
        return ScanStatusResponse(
            isScanning: state.isScanning,
            lastScanDate: state.lastScanDate,
            lastScanProjects: state.lastScanProjects,
            lastScanFiles: state.lastScanFiles,
            projectCount: projectCount,
            fileCount: fileCount
        )
    }
}
