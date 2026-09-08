import XCTVapor
import PrintPlexCore
@testable import PrintPlexServerApp

final class MCPTests: XCTestCase {
    var app: Application!
    var mediaDir: URL!
    var dataDir: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
        mediaDir = base.appendingPathComponent("printplex-mcp-media-\(UUID().uuidString)")
        dataDir = base.appendingPathComponent("printplex-mcp-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        setenv("PRINTPLEX_MEDIA_PATH", mediaDir.path, 1)
        setenv("PRINTPLEX_DATA_PATH", dataDir.path, 1)
        setenv("PRINTPLEX_DB_IN_MEMORY", "1", 1)
        setenv("PRINTPLEX_SCAN_INTERVAL_MIN", "0", 1)
        setenv("SHOPIFY_STORE_DOMAIN", "", 1)
        setenv("SHOPIFY_ACCESS_TOKEN", "", 1)
        unsetenv("PRINTPLEX_ADMIN_USERNAME")
        unsetenv("PRINTPLEX_ADMIN_PASSWORD")

        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
        try? FileManager.default.removeItem(at: mediaDir)
        try? FileManager.default.removeItem(at: dataDir)
    }

    // MARK: - Helpers

    private func rpc(_ body: [String: Any]) throws -> ByteBuffer {
        ByteBuffer(data: try JSONSerialization.data(withJSONObject: body))
    }

    private func callTool(_ name: String, arguments: [String: Any] = [:]) async throws -> XCTHTTPResponse {
        var captured: XCTHTTPResponse!
        try await app.test(.POST, "api/mcp", beforeRequest: { req in
            req.headers.replaceOrAdd(name: "Content-Type", value: "application/json")
            req.headers.replaceOrAdd(name: "Accept", value: "application/json")
            req.body = try rpc([
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": name, "arguments": arguments],
            ])
        }, afterResponse: { res async throws in
            captured = res
        })
        return captured
    }

    // MARK: - Tests

    func testMcpEndpointRequiresAuth() async throws {
        app.authEnforcementEnabled = true
        try await app.test(.POST, "api/mcp", beforeRequest: { req in
            req.headers.replaceOrAdd(name: "Content-Type", value: "application/json")
            req.headers.replaceOrAdd(name: "Accept", value: "application/json")
            req.body = try rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]])
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    func testInitializeHandshakeSucceeds() async throws {
        try await app.test(.POST, "api/mcp", beforeRequest: { req in
            req.headers.replaceOrAdd(name: "Content-Type", value: "application/json")
            req.headers.replaceOrAdd(name: "Accept", value: "application/json")
            req.body = try rpc([
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18",
                    "capabilities": [String: Any](),
                    "clientInfo": ["name": "test-client", "version": "1.0"],
                ],
            ])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("\"protocolVersion\""))
        })
    }

    func testToolsListReturnsRegisteredProjectTools() async throws {
        try await app.test(.POST, "api/mcp", beforeRequest: { req in
            req.headers.replaceOrAdd(name: "Content-Type", value: "application/json")
            req.headers.replaceOrAdd(name: "Accept", value: "application/json")
            req.body = try rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("\"list_projects\""))
        })
    }

    func testUnknownToolReturnsErrorResult() async throws {
        let res = try await callTool("nonexistent_tool")
        XCTAssertEqual(res.status, .ok)
        XCTAssertTrue(res.body.string.contains("\"isError\":true"))
    }

    func testListProjectsToolReturnsEmptyArrayWhenNoProjects() async throws {
        let res = try await callTool("list_projects")
        XCTAssertEqual(res.status, .ok)
        XCTAssertFalse(res.body.string.contains("\"isError\":true"))
        XCTAssertTrue(res.body.string.contains("\"structuredContent\":[]"))
    }

    func testGetProjectToolReturns404ForUnknownId() async throws {
        let res = try await callTool("get_project", arguments: ["projectId": UUID().uuidString])
        XCTAssertEqual(res.status, .ok)
        XCTAssertTrue(res.body.string.contains("\"isError\":true"))
        XCTAssertTrue(res.body.string.contains("Projet introuvable"))
    }

    func testListFilesToolReturnsEmptyArrayWhenNoFiles() async throws {
        let res = try await callTool("list_files")
        XCTAssertEqual(res.status, .ok)
        XCTAssertFalse(res.body.string.contains("\"isError\":true"))
        XCTAssertTrue(res.body.string.contains("\"structuredContent\":[]"))
    }

    func testGetScanStatusToolReturnsStatus() async throws {
        let res = try await callTool("get_scan_status")
        XCTAssertEqual(res.status, .ok)
        XCTAssertTrue(res.body.string.contains("\"isScanning\""))
    }

    func testListLibrariesToolReturnsEmptyArrayWhenNoLibraries() async throws {
        let res = try await callTool("list_libraries")
        XCTAssertEqual(res.status, .ok)
        XCTAssertFalse(res.body.string.contains("\"isError\":true"))
    }

    func testDeleteLibraryToolReturns404ForUnknownId() async throws {
        let res = try await callTool("delete_library", arguments: ["libraryId": UUID().uuidString])
        XCTAssertEqual(res.status, .ok)
        XCTAssertTrue(res.body.string.contains("\"isError\":true"))
    }

    func testCreatePrinterToolPersistsPrinter() async throws {
        let res = try await callTool("create_printer", arguments: [
            "name": "Test Printer", "buildX": 220, "buildY": 220, "buildZ": 250,
            "perimeterSpeedMMPS": 40, "infillSpeedMMPS": 80, "nozzleDiameterMM": 0.4,
            "defaultLayerHeightMM": 0.2, "supportsPercent": 10, "purgePercent": 5, "speedEfficiency": 0.85,
        ])
        XCTAssertEqual(res.status, .ok)
        XCTAssertFalse(res.body.string.contains("\"isError\":true"))
        XCTAssertTrue(res.body.string.contains("Test Printer"))
    }
}
