# MCP Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose PrintPlexServer's library (projects, files, scan, libraries, printers, materials, settings, Shopify, ForgeCore) to MCP-compatible LLM agents over a new `/api/mcp` HTTP endpoint, reusing the existing REST business logic and `X-API-Key` auth.

**Architecture:** A single `Server` (from the official `modelcontextprotocol/swift-sdk`) is created once at boot and wired to a `StatelessHTTPServerTransport`. A new `MCPController` route (`POST /api/mcp`, gated by the existing `AuthMiddleware` for free) converts each request into the transport's framework-agnostic `HTTPRequest`/`HTTPResponse` types. Every REST controller gets its request-handling logic split into a thin `req`-based route closure plus a `static` helper taking explicit parameters (`Database`/`Application` instead of `Request`) — both the REST route and the matching MCP tool call the same static helper, so no business logic is duplicated. One new Swift file per controller group (`Sources/PrintPlexServerApp/MCP/*MCPTools.swift`) declares that group's `Tool` list and dispatches `tools/call` into the shared static helpers; a small `MCPToolRegistry` aggregates every group.

**Tech Stack:** Swift 6.0, Vapor 4.99+, Fluent 4.9+ / FluentSQLiteDriver 4.6+, `modelcontextprotocol/swift-sdk` (product name `MCP`) from 0.11.0.

## Global Constraints

- Swift tools version 6.0 (existing `Package.swift`) — do not lower it.
- New dependency pinned as `from: "0.11.0"` (matches the existing `from:`-pinning style already used for `vapor`/`fluent` in `Package.swift`).
- `MCP` product is a dependency of the `PrintPlexServerApp` executable target only — **not** `PrintPlexCore` (the native client doesn't need it).
- Every MCP tool call must route through the exact same static helper the equivalent REST route calls — no reimplemented business logic.
- `/api/mcp` lives under `/api/*` so it is auth-gated by the existing `AuthMiddleware` automatically — no new auth code.
- Binary/streaming endpoints (`FileController.download/thumbnail/original`, `ScanController.events` SSE) are **not** exposed as MCP tools — a single JSON-RPC `tools/call` can't model a binary stream or a live push feed. (This is a scope correction versus the design doc's table, which listed `get_scan_events` — discovered while writing this plan; `trigger_scan`/`get_scan_status` still cover scan visibility.)
- `get_shopify_settings` never returns the plaintext Shopify access token to an agent (unlike the dashboard's own settings screen, which needs it to prefill a form for a human) — only `storeDomain`/`configured`.
- Destructive tools (`delete_library`, `delete_printer`) carry `Tool.Annotations(destructiveHint: true)`.

---

### Task 1: Add the MCP Swift SDK dependency

**Files:**
- Modify: `Package.swift`

**Interfaces:**
- Produces: the `MCP` module, importable as `import MCP` from `PrintPlexServerApp` target files.

- [ ] **Step 1: Add the dependency and product**

In `Package.swift`, add to the `dependencies:` array (after the `fluent-sqlite-driver` entry):

```swift
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
```

Add to the `PrintPlexServerApp` executable target's `dependencies:` array (after `FluentSQLiteDriver`):

```swift
                .product(name: "MCP", package: "swift-sdk"),
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: `Build complete!` — the `MCP` module resolves and compiles with no source changes needed yet.

- [ ] **Step 3: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "deps: add MCP Swift SDK for the upcoming MCP server"
```

---

### Task 2: MCP plumbing skeleton (Server, transport, Vapor bridge, empty registry)

**Files:**
- Create: `Sources/PrintPlexServerApp/MCP/MCPBridge.swift`
- Create: `Sources/PrintPlexServerApp/MCP/MCPToolRegistry.swift`
- Create: `Sources/PrintPlexServerApp/MCP/MCPController.swift`
- Modify: `Sources/PrintPlexServerApp/routes.swift`
- Modify: `Sources/PrintPlexServerApp/configure.swift`
- Test: `Tests/PrintPlexServerAppTests/MCPTests.swift`

**Interfaces:**
- Produces: `mcpHTTPRequest(from:) -> MCP.HTTPRequest`, `vaporResponse(from:) -> Response`, `decodeArguments<T: Decodable>(_:from:) throws -> T`, `toolResult<T: Encodable>(_:) throws -> CallTool.Result`, `toolSuccess(_:) -> CallTool.Result`, `toolErrorResult(_:) -> CallTool.Result`, `MCPToolError`, `objectSchema(properties:required:) -> Value`, `stringProp/intProp/numberProp/boolProp/arrayProp(_:) -> Value` — every later task's `*MCPTools.swift` file uses these. `MCPToolRegistry.toolGroups: [[Tool]]` and `.callHandlers: [(String, [String: Value]?, Application) async throws -> CallTool.Result?]` — every later task appends one entry to each.

- [ ] **Step 1: Write the Vapor ↔ MCP HTTP bridge and tool-result helpers**

Create `Sources/PrintPlexServerApp/MCP/MCPBridge.swift`:

```swift
import Vapor
import Foundation
import MCP

// MARK: - Vapor <-> MCP HTTP bridge

func mcpHTTPRequest(from req: Request) -> MCP.HTTPRequest {
    var headers: [String: String] = [:]
    for (name, value) in req.headers {
        headers[name] = value
    }
    let bodyData = req.body.data.map { Data(buffer: $0) }
    return MCP.HTTPRequest(
        method: req.method.rawValue,
        headers: headers,
        body: bodyData,
        path: req.url.path
    )
}

func vaporResponse(from mcpResponse: MCP.HTTPResponse) -> Response {
    switch mcpResponse {
    case .accepted(let headers):
        return rawResponse(status: .accepted, headers: headers, body: nil)
    case .ok(let headers):
        return rawResponse(status: .ok, headers: headers, body: nil)
    case .data(let data, let headers):
        return rawResponse(status: .ok, headers: headers, body: data)
    case .error(let statusCode, _, _, _):
        return rawResponse(status: HTTPStatus(statusCode: statusCode), headers: mcpResponse.headers, body: mcpResponse.bodyData)
    case .stream:
        // StatelessHTTPServerTransport never returns this for POST (its own
        // doc comment: "POST requests receive direct JSON responses (no SSE
        // streaming)") — kept exhaustive in case a future SDK version adds
        // stream support we haven't opted into.
        return rawResponse(status: .notImplemented, headers: [:], body: nil)
    }
}

private func rawResponse(status: HTTPStatus, headers: [String: String], body: Data?) -> Response {
    var vaporHeaders = HTTPHeaders()
    for (name, value) in headers {
        vaporHeaders.replaceOrAdd(name: name, value: value)
    }
    let response = Response(status: status, headers: vaporHeaders)
    if let body {
        response.body = .init(data: body)
    }
    return response
}

// MARK: - Value <-> Codable bridging

enum MCPToolError: Error {
    case invalidArguments(String)
}

/// Decodes a tool call's `arguments` dictionary into an existing `Content`
/// (or any `Decodable`) request type — the same type the matching REST route
/// already decodes from its JSON body, so argument parsing stays identical
/// between the two entry points.
func decodeArguments<T: Decodable>(_ type: T.Type, from arguments: [String: Value]?) throws -> T {
    let value = Value.object(arguments ?? [:])
    let data = try JSONEncoder().encode(value)
    do {
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        throw MCPToolError.invalidArguments("\(error)")
    }
}

func toolResult<T: Encodable>(_ value: T) throws -> CallTool.Result {
    let data = try JSONEncoder().encode(value)
    let text = String(decoding: data, as: UTF8.self)
    return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: value)
}

func toolSuccess(_ message: String) -> CallTool.Result {
    CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)])
}

func toolErrorResult(_ message: String) -> CallTool.Result {
    CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
}

// MARK: - JSON Schema builders for Tool.inputSchema

func objectSchema(properties: [String: Value] = [:], required: [String] = []) -> Value {
    .object([
        "type": .string("object"),
        "properties": .object(properties),
        "required": .array(required.map(Value.string)),
    ])
}

func stringProp(_ description: String) -> Value {
    .object(["type": .string("string"), "description": .string(description)])
}

func intProp(_ description: String) -> Value {
    .object(["type": .string("integer"), "description": .string(description)])
}

func numberProp(_ description: String) -> Value {
    .object(["type": .string("number"), "description": .string(description)])
}

func boolProp(_ description: String) -> Value {
    .object(["type": .string("boolean"), "description": .string(description)])
}

func arrayProp(_ description: String, items: Value = .object(["type": .string("string")])) -> Value {
    .object(["type": .string("array"), "description": .string(description), "items": items])
}
```

- [ ] **Step 2: Write the (initially empty) tool registry**

Create `Sources/PrintPlexServerApp/MCP/MCPToolRegistry.swift`:

```swift
import Vapor
import MCP

/// Each controller-group's `*MCPTools.swift` file appends its own
/// `.tools`/`.call` to these two arrays — see Task 3 onward.
enum MCPToolRegistry {
    static let toolGroups: [[Tool]] = []
    static let callHandlers: [(String, [String: Value]?, Application) async throws -> CallTool.Result?] = []

    static var allTools: [Tool] { toolGroups.flatMap { $0 } }

    static func call(name: String, arguments: [String: Value]?, app: Application) async throws -> CallTool.Result {
        for handler in callHandlers {
            if let result = try await handler(name, arguments, app) {
                return result
            }
        }
        return toolErrorResult("Tool inconnu : \(name)")
    }
}
```

- [ ] **Step 3: Write the Server bootstrap + route controller**

Create `Sources/PrintPlexServerApp/MCP/MCPController.swift`:

```swift
import Vapor
import MCP

struct MCPController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let mcp = routes.grouped("api", "mcp")
        mcp.on(.POST, body: .collect(maxSize: "10mb"), use: handle)
    }

    @Sendable
    func handle(req: Request) async throws -> Response {
        let transport = req.application.mcpTransport
        let mcpRequest = mcpHTTPRequest(from: req)
        let mcpResponse = await transport.handleRequest(mcpRequest)
        return vaporResponse(from: mcpResponse)
    }
}

/// Creates the MCP `Server`, wires it to a `StatelessHTTPServerTransport`
/// (single JSON request/response per call — this server never needs to push
/// unsolicited notifications, so the simpler stateless transport is enough,
/// no session/SSE machinery), and registers the two method handlers every
/// tool group dispatches through. Called once from `configure(_:)`.
func configureMCPServer(_ app: Application) async throws {
    let transport = StatelessHTTPServerTransport(
        // The server is reached over the public internet behind the existing
        // X-API-Key gate (AuthMiddleware), not bound to localhost — the
        // default origin validator would reject every real request. Per
        // OriginValidator.disabled's own doc comment: "Use for cloud
        // deployments where DNS rebinding is not a threat" — true here since
        // the API key is the actual security boundary, not Origin/Host.
        validationPipeline: StandardValidationPipeline(validators: [
            OriginValidator.disabled,
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ])
    )
    let server = Server(
        name: "PrintPlexServer",
        version: printPlexServerVersion,
        capabilities: .init(tools: .init(listChanged: false))
    )
    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: MCPToolRegistry.allTools)
    }
    await server.withMethodHandler(CallTool.self) { params in
        do {
            return try await MCPToolRegistry.call(name: params.name, arguments: params.arguments, app: app)
        } catch let argError as MCPToolError {
            switch argError {
            case .invalidArguments(let message):
                return toolErrorResult("Arguments invalides : \(message)")
            }
        } catch let abort as Abort {
            return toolErrorResult(abort.reason)
        } catch {
            return toolErrorResult(String(describing: error))
        }
    }
    try await server.start(transport: transport)
    app.mcpTransport = transport
}

struct MCPTransportKey: StorageKey { typealias Value = StatelessHTTPServerTransport }

extension Application {
    var mcpTransport: StatelessHTTPServerTransport {
        get { storage[MCPTransportKey.self]! }
        set { storage[MCPTransportKey.self] = newValue }
    }
}
```

- [ ] **Step 4: Wire it into app boot and routing**

In `Sources/PrintPlexServerApp/configure.swift`, add right before `try routes(app)`:

```swift
    try await configureMCPServer(app)

```

In `Sources/PrintPlexServerApp/routes.swift`, add to the `try app.register(collection: ...)` block (after `ForgeCoreController()`):

```swift
    try app.register(collection: MCPController())
```

- [ ] **Step 5: Write the plumbing tests**

Create `Tests/PrintPlexServerAppTests/MCPTests.swift`:

```swift
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

    func testToolsListReturnsEmptyArrayBeforeAnyGroupIsRegistered() async throws {
        try await app.test(.POST, "api/mcp", beforeRequest: { req in
            req.headers.replaceOrAdd(name: "Content-Type", value: "application/json")
            req.headers.replaceOrAdd(name: "Accept", value: "application/json")
            req.body = try rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("\"tools\":[]"))
        })
    }

    func testUnknownToolReturnsErrorResult() async throws {
        let res = try await callTool("nonexistent_tool")
        XCTAssertEqual(res.status, .ok)
        XCTAssertTrue(res.body.string.contains("\"isError\":true"))
    }
}
```

Note: this test file references `callTool(_:arguments:)`, used starting Task 3 — it's fine for it to be unused by any test yet in this task (Swift doesn't warn on an unused private method the same way as an unused variable, and later tasks use it immediately).

- [ ] **Step 6: Run the tests**

Run: `swift test --filter MCPTests`
Expected: 4 tests pass (`testMcpEndpointRequiresAuth`, `testInitializeHandshakeSucceeds`, `testToolsListReturnsEmptyArrayBeforeAnyGroupIsRegistered`, `testUnknownToolReturnsErrorResult`).

- [ ] **Step 7: Commit**

```bash
git add Sources/PrintPlexServerApp/MCP Sources/PrintPlexServerApp/configure.swift Sources/PrintPlexServerApp/routes.swift Tests/PrintPlexServerAppTests/MCPTests.swift
git commit -m "feat: add MCP server plumbing (Vapor bridge, empty tool registry, /api/mcp route)"
```

---

### Task 3: Projects MCP tools

**Files:**
- Modify: `Sources/PrintPlexServerApp/Controllers/ProjectController.swift`
- Modify: `Sources/PrintPlexServerApp/EstimateSupport.swift`
- Create: `Sources/PrintPlexServerApp/MCP/ProjectMCPTools.swift`
- Modify: `Sources/PrintPlexServerApp/MCP/MCPToolRegistry.swift`
- Modify: `Tests/PrintPlexServerAppTests/MCPTests.swift`

**Interfaces:**
- Consumes: `decodeArguments`, `toolResult`, `objectSchema`/`stringProp`/etc., `MCPToolError`, `MCPToolRegistry.toolGroups`/`.callHandlers` (Task 2).
- Produces: `ProjectController.fetchIndex(on:)`, `.fetchDetail(id:on:)`, `.applyUpdate(_:to:on:)`, `.fetchEstimate(id:query:on:)`, `.fetchShopifyMatch(id:app:)`, `.find(id:on:) -> ProjectModel` — reused directly by `FileMCPTools` is not needed, but `EstimateSupport.inputs(query:on:)` (new overload) is reused by Task 4.

- [ ] **Step 1: Add the `query:on:` overload to `EstimateSupport`**

In `Sources/PrintPlexServerApp/EstimateSupport.swift`, replace the `inputs(from:)` function with:

```swift
    static func inputs(from req: Request) async throws
        -> (PrinterProfile, PrintMaterial, PrintSettings, ManualWorkLevel) {
        try await inputs(query: try req.query.decode(EstimateQuery.self), on: req.db)
    }

    static func inputs(query: EstimateQuery, on db: Database) async throws
        -> (PrinterProfile, PrintMaterial, PrintSettings, ManualWorkLevel) {
        let printerModel: PrinterModel?
        if let id = query.printerId {
            printerModel = try await PrinterModel.find(id, on: db)
        } else {
            printerModel = try await PrinterModel.query(on: db).sort(\.$sortOrder).first()
        }
        guard let printerModel else {
            throw Abort(.notFound, reason: "Imprimante inconnue")
        }

        let materialModel: MaterialModel?
        if let id = query.materialId {
            materialModel = try await MaterialModel.find(id, on: db)
        } else {
            materialModel = try await MaterialModel.query(on: db).sort(\.$sortOrder).first()
        }
        guard let materialModel else {
            throw Abort(.notFound, reason: "Matériau inconnu")
        }

        var settings = PrintSettings()
        if let v = query.layerHeightMM { settings.layerHeightMM = v }
        if let v = query.shellCount { settings.shellCount = v }
        if let v = query.infillPercent { settings.infillPercent = v }

        let manual = query.manualWork.flatMap(ManualWorkLevel.init(rawValue:)) ?? .aucun
        return (printerModel.toDTO(), materialModel.toDTO(), settings, manual)
    }
```

- [ ] **Step 2: Extract static helpers in `ProjectController`**

In `Sources/PrintPlexServerApp/Controllers/ProjectController.swift`, replace the whole body from `func index` through the closing `}` of `private func find` (i.e. everything from `@Sendable\n    func index` to the end of the `find` method, right before the struct's closing brace) with:

```swift
    @Sendable
    func index(req: Request) async throws -> [ProjectDTO] {
        try await Self.fetchIndex(on: req.db)
    }

    static func fetchIndex(on db: Database) async throws -> [ProjectDTO] {
        let models = try await ProjectModel.query(on: db)
            .sort(\.$lastModifiedAt, .descending)
            .all()

        // One query for every project's files (instead of one query per
        // project) so cover image + part/file counts stay cheap even with
        // many projects — the grid view needs these on every card.
        let allProjectFiles = try await FileModel.query(on: db)
            .filter(\.$project.$id != nil)
            .all()
        let filesByProject = Dictionary(grouping: allProjectFiles) { $0.$project.id! }

        return models.map { model in
            let files = filesByProject[model.id!] ?? []
            let (coverFileId, partsCount, totalFileCount, imageCount) = model.coverAndCounts(from: files)
            return model.toDTO(coverFileId: coverFileId, partsCount: partsCount,
                              totalFileCount: totalFileCount, imageCount: imageCount,
                              hasManualEstimate: model.hasManualEstimate(from: files))
        }
    }

    @Sendable
    func detail(req: Request) async throws -> ProjectDTO {
        try await Self.fetchDetail(id: requireProjectID(req), on: req.db)
    }

    static func fetchDetail(id: UUID, on db: Database) async throws -> ProjectDTO {
        let model = try await find(id: id, on: db)
        let files = try await FileModel.query(on: db)
            .filter(\.$project.$id == model.requireID())
            .sort(\.$fileName)
            .all()
        let (coverFileId, partsCount, totalFileCount, imageCount) = model.coverAndCounts(from: files)
        return model.toDTO(files: files.map { $0.toDTO() }, coverFileId: coverFileId,
                          partsCount: partsCount, totalFileCount: totalFileCount, imageCount: imageCount,
                          hasManualEstimate: model.hasManualEstimate(from: files))
    }

    /// Updates project metadata in the DB **and** in the folder's info.json,
    /// so the library stays the source of truth for the next scan.
    @Sendable
    func update(req: Request) async throws -> ProjectDTO {
        let model = try await find(req)
        let body = try req.content.decode(ProjectUpdateRequest.self)
        return try await Self.applyUpdate(body, to: model, on: req.db)
    }

    static func applyUpdate(_ body: ProjectUpdateRequest, to model: ProjectModel, on db: Database) async throws -> ProjectDTO {
        // `String?` can't distinguish "field omitted" from "explicitly cleared"
        // over JSON — both decode to nil. So for category/creator, an empty
        // string is the client's way of asking to clear the field (the "À
        // faire" incomplete-metadata check already treats empty as missing,
        // and this is what the sidebar's "Supprimer" context menu sends).
        if let v = body.name { model.name = v }
        if let v = body.projectDescription { model.projectDescription = v }
        if let v = body.category { model.category = v.isEmpty ? nil : v }
        if let v = body.creator { model.creator = v.isEmpty ? nil : v }
        if let v = body.tags { model.tags = v }
        if let v = body.suggestedMaterials { model.suggestedMaterials = v }
        if let v = body.multiColor { model.multiColor = v }
        if let v = body.notes { model.notes = v }
        if let v = body.alreadyPrinted { model.alreadyPrinted = v }
        if let v = body.sourceUrl { model.sourceUrl = v.isEmpty ? nil : v }
        if let v = body.sourceHardware { model.sourceHardware = v }
        if let v = body.sourceEstimatedWeight { model.sourceEstimatedWeight = v.isEmpty ? nil : v }
        if let v = body.sourceEstimatedPrintTime { model.sourceEstimatedPrintTime = v.isEmpty ? nil : v }
        if let v = body.sourceInstructionImages { model.sourceInstructionImages = v }
        // DB-only (see ProjectDTO) — no info.json mirror below, unlike the other source_* fields.
        if let v = body.sourceScrapeStatus { model.sourceScrapeStatus = v.isEmpty ? nil : v }
        if let v = body.sourceScrapeError { model.sourceScrapeError = v.isEmpty ? nil : v }
        if let v = body.shopifyProductId { model.shopifyProductId = v }
        if let v = body.coverImageFileName { model.coverImageFileName = v }
        try await model.save(on: db)

        try LibraryScanner.updateProjectInfo(in: model.folderPath) { info in
            if let v = body.name { info.nom = v }
            if let v = body.projectDescription { info.description = v }
            if let v = body.category { info.categorie = v.isEmpty ? nil : v }
            if let v = body.creator { info.createur = v.isEmpty ? nil : v }
            if let v = body.tags { info.tags = v }
            if let v = body.suggestedMaterials { info.materiaux_suggeres = v }
            if let v = body.multiColor { info.multi_couleur = v }
            if let v = body.notes { info.notes = v }
            if let v = body.alreadyPrinted { info.deja_imprime = v }
            if let v = body.sourceUrl { info.source_url = v.isEmpty ? nil : v }
            if let v = body.sourceHardware { info.source_hardware = v }
            if let v = body.sourceEstimatedWeight { info.source_estimated_weight = v.isEmpty ? nil : v }
            if let v = body.sourceEstimatedPrintTime { info.source_estimated_print_time = v.isEmpty ? nil : v }
            if let v = body.sourceInstructionImages { info.source_instruction_images = v }
            if let v = body.shopifyProductId { info.shopify_product_id = v }
            if let v = body.coverImageFileName { info.image_principale = v }
        }

        return model.toDTO()
    }

    /// Combined estimate over every 3MF part that has parsed mesh stats.
    @Sendable
    func estimate(req: Request) async throws -> PrintEstimate {
        let id = try requireProjectID(req)
        let query = try req.query.decode(EstimateQuery.self)
        return try await Self.fetchEstimate(id: id, query: query, on: req.db)
    }

    static func fetchEstimate(id: UUID, query: EstimateQuery, on db: Database) async throws -> PrintEstimate {
        let model = try await find(id: id, on: db)
        let files = try await FileModel.query(on: db)
            .filter(\.$project.$id == model.requireID())
            .all()

        let (printer, material, settings, manual) = try await EstimateSupport.inputs(query: query, on: db)

        let estimates = files.compactMap { file -> PrintEstimate? in
            guard file.fileRole == .modelPart, let stats = file.meshStats else { return nil }
            return PrintEstimator.estimate(
                parsed: EstimateSupport.parserResult(from: stats),
                printer: printer, material: material, settings: settings
            )
        }
        guard !estimates.isEmpty else {
            throw Abort(.conflict, reason: "Aucune pièce avec statistiques de maillage — lancez un scan d'abord")
        }

        let base = PrintEstimator.total(estimates: estimates, printer: printer, material: material)
        guard manual != .aucun else { return base }
        // Manual work applies once per project, not per part
        return PrintEstimate(
            filamentLengthM: base.filamentLengthM,
            filamentWeightG: base.filamentWeightG,
            printTimeSeconds: base.printTimeSeconds,
            layerCount: base.layerCount,
            fitsOnBed: base.fitsOnBed,
            printerName: base.printerName,
            materialName: base.materialName,
            filamentCostEur: base.filamentCostEur,
            timeCostEur: base.timeCostEur,
            manualCostEur: manual.cost
        )
    }

    @Sendable
    func shopifyMatch(req: Request) async throws -> ShopifyMatchResponse {
        try await Self.fetchShopifyMatch(id: requireProjectID(req), app: req.application)
    }

    static func fetchShopifyMatch(id: UUID, app: Application) async throws -> ShopifyMatchResponse {
        guard let cache = app.shopifyCache else {
            throw Abort(.serviceUnavailable, reason: "Shopify non configuré (SHOPIFY_STORE_DOMAIN / SHOPIFY_ACCESS_TOKEN)")
        }
        let model = try await find(id: id, on: app.db)
        do {
            _ = try await cache.productsSyncingIfNeeded()
        } catch {
            throw ShopifyController.abortify(error)
        }
        guard let product = await cache.match(projectName: model.name,
                                              explicitProductId: model.shopifyProductId) else {
            throw Abort(.notFound, reason: "Aucun produit Shopify correspondant")
        }
        return ShopifyMatchResponse(product: product,
                                    url: await cache.url(for: product)?.absoluteString)
    }

    private func find(_ req: Request) async throws -> ProjectModel {
        try await Self.find(id: requireProjectID(req), on: req.db)
    }

    static func find(id: UUID, on db: Database) async throws -> ProjectModel {
        guard let model = try await ProjectModel.find(id, on: db) else {
            throw Abort(.notFound, reason: "Projet introuvable")
        }
        return model
    }

    private func requireProjectID(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("projectID", as: UUID.self) else {
            throw Abort(.notFound, reason: "Projet introuvable")
        }
        return id
    }
```

- [ ] **Step 3: Write `ProjectMCPTools.swift`**

Create `Sources/PrintPlexServerApp/MCP/ProjectMCPTools.swift`:

```swift
import Vapor
import PrintPlexCore
import MCP

enum ProjectMCPTools {
    static let tools: [Tool] = [
        Tool(
            name: "list_projects",
            description: "Liste tous les projets de la bibliothèque, triés par date de modification décroissante.",
            inputSchema: objectSchema()
        ),
        Tool(
            name: "get_project",
            description: "Détail complet d'un projet (métadonnées, fichiers, tags, catégorie, créateur).",
            inputSchema: objectSchema(
                properties: ["projectId": stringProp("UUID du projet")],
                required: ["projectId"]
            )
        ),
        Tool(
            name: "update_project",
            description: "Met à jour les métadonnées d'un projet (nom, description, catégorie, créateur, tags, matériaux suggérés, notes, statut déjà imprimé, infos de source...). Seuls les champs fournis sont modifiés ; une chaîne vide efface un champ texte optionnel.",
            inputSchema: objectSchema(
                properties: [
                    "projectId": stringProp("UUID du projet"),
                    "name": stringProp("Nouveau nom"),
                    "projectDescription": stringProp("Nouvelle description"),
                    "category": stringProp("Nouvelle catégorie (chaîne vide pour effacer)"),
                    "creator": stringProp("Nouveau créateur (chaîne vide pour effacer)"),
                    "tags": arrayProp("Liste complète des tags (remplace l'existante)"),
                    "suggestedMaterials": arrayProp("Liste complète des matériaux suggérés"),
                    "multiColor": boolProp("Multi-couleur"),
                    "notes": stringProp("Notes libres"),
                    "alreadyPrinted": boolProp("Déjà imprimé"),
                    "sourceUrl": stringProp("URL source (chaîne vide pour effacer)"),
                ],
                required: ["projectId"]
            )
        ),
        Tool(
            name: "get_project_estimate",
            description: "Estimation d'impression (temps, filament, coût) sur l'ensemble des pièces d'un projet.",
            inputSchema: objectSchema(
                properties: [
                    "projectId": stringProp("UUID du projet"),
                    "printerId": stringProp("UUID de l'imprimante (défaut : la première configurée)"),
                    "materialId": stringProp("UUID du matériau (défaut : le premier configuré)"),
                    "manualWork": stringProp("Niveau de travail manuel (aucun, leger, modere, important)"),
                ],
                required: ["projectId"]
            )
        ),
        Tool(
            name: "get_project_shopify_match",
            description: "Trouve le produit Shopify correspondant à ce projet, si configuré.",
            inputSchema: objectSchema(
                properties: ["projectId": stringProp("UUID du projet")],
                required: ["projectId"]
            )
        ),
    ]

    static func call(_ name: String, _ arguments: [String: Value]?, app: Application) async throws -> CallTool.Result? {
        switch name {
        case "list_projects":
            return try await toolResult(ProjectController.fetchIndex(on: app.db))

        case "get_project":
            return try await toolResult(ProjectController.fetchDetail(id: projectID(from: arguments), on: app.db))

        case "update_project":
            let id = try projectID(from: arguments)
            let body = try decodeArguments(ProjectUpdateRequest.self, from: arguments)
            let model = try await ProjectController.find(id: id, on: app.db)
            return try await toolResult(ProjectController.applyUpdate(body, to: model, on: app.db))

        case "get_project_estimate":
            let id = try projectID(from: arguments)
            let query = try decodeArguments(EstimateQuery.self, from: arguments)
            return try await toolResult(ProjectController.fetchEstimate(id: id, query: query, on: app.db))

        case "get_project_shopify_match":
            return try await toolResult(ProjectController.fetchShopifyMatch(id: projectID(from: arguments), app: app))

        default:
            return nil
        }
    }

    private static func projectID(from arguments: [String: Value]?) throws -> UUID {
        guard let raw = arguments?["projectId"]?.stringValue, let id = UUID(uuidString: raw) else {
            throw MCPToolError.invalidArguments("projectId manquant ou invalide")
        }
        return id
    }
}
```

- [ ] **Step 4: Register the group**

In `Sources/PrintPlexServerApp/MCP/MCPToolRegistry.swift`, change:

```swift
    static let toolGroups: [[Tool]] = []
    static let callHandlers: [(String, [String: Value]?, Application) async throws -> CallTool.Result?] = []
```

to:

```swift
    static let toolGroups: [[Tool]] = [
        ProjectMCPTools.tools,
    ]
    static let callHandlers: [(String, [String: Value]?, Application) async throws -> CallTool.Result?] = [
        ProjectMCPTools.call,
    ]
```

- [ ] **Step 5: Add the test**

In `Tests/PrintPlexServerAppTests/MCPTests.swift`, add:

```swift
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
```

- [ ] **Step 6: Run the tests**

Run: `swift test --filter MCPTests`
Expected: all tests pass, including the two new ones and everything from Task 2.

- [ ] **Step 7: Commit**

```bash
git add Sources/PrintPlexServerApp/Controllers/ProjectController.swift Sources/PrintPlexServerApp/EstimateSupport.swift Sources/PrintPlexServerApp/MCP/ProjectMCPTools.swift Sources/PrintPlexServerApp/MCP/MCPToolRegistry.swift Tests/PrintPlexServerAppTests/MCPTests.swift
git commit -m "feat: add Projects MCP tools (list/get/update/estimate/shopify-match)"
```

---

### Task 4: Files MCP tools

**Files:**
- Modify: `Sources/PrintPlexServerApp/Controllers/FileController.swift`
- Create: `Sources/PrintPlexServerApp/MCP/FileMCPTools.swift`
- Modify: `Sources/PrintPlexServerApp/MCP/MCPToolRegistry.swift`
- Modify: `Tests/PrintPlexServerAppTests/MCPTests.swift`

**Interfaces:**
- Consumes: `EstimateSupport.inputs(query:on:)` (Task 3), the shared bridge helpers (Task 2).
- Produces: `FileController.fetchIndex(kind:on:)`, `.fetchUnsorted(on:)`, `.fetchStats(on:)`, `.find(id:on:) -> FileModel`, `.applyUpdate(_:to:on:)`, `.fetchEstimate(file:query:on:)`.

- [ ] **Step 1: Extract static helpers in `FileController`**

In `Sources/PrintPlexServerApp/Controllers/FileController.swift`, replace `index` through `estimate` and the trailing `find` (leave `download`/`thumbnail`/`original` untouched) with:

```swift
    @Sendable
    func index(req: Request) async throws -> [FileDTO] {
        let kind = try? req.query.get(String.self, at: "kind")
        return try await Self.fetchIndex(kind: kind, on: req.db)
    }

    static func fetchIndex(kind: String?, on db: Database) async throws -> [FileDTO] {
        var query = FileModel.query(on: db)
        if let kind, !kind.isEmpty {
            query = query.filter(\.$kindRaw == kind)
        }
        let models = try await query.sort(\.$fileName).all()
        return models.map { $0.toDTO() }
    }

    @Sendable
    func unsorted(req: Request) async throws -> [FileDTO] {
        try await Self.fetchUnsorted(on: req.db)
    }

    static func fetchUnsorted(on db: Database) async throws -> [FileDTO] {
        let models = try await FileModel.query(on: db)
            .filter(\.$project.$id == .null)
            .sort(\.$fileName)
            .all()
        return models.map { $0.toDTO() }
    }

    @Sendable
    func stats(req: Request) async throws -> FileKindCounts {
        try await Self.fetchStats(on: req.db)
    }

    static func fetchStats(on db: Database) async throws -> FileKindCounts {
        async let stl = FileModel.query(on: db).filter(\.$kindRaw == FileKind.stl.rawValue).count()
        async let threeMF = FileModel.query(on: db).filter(\.$kindRaw == FileKind.threeMF.rawValue).count()
        async let obj = FileModel.query(on: db).filter(\.$kindRaw == FileKind.obj.rawValue).count()
        async let step = FileModel.query(on: db).filter(\.$kindRaw == FileKind.step.rawValue).count()
        async let other = FileModel.query(on: db).filter(\.$kindRaw == FileKind.other.rawValue).count()
        async let unsorted = FileModel.query(on: db).filter(\.$project.$id == .null).count()
        return try await FileKindCounts(
            stl: stl, threeMF: threeMF, obj: obj, step: step, other: other, unsorted: unsorted
        )
    }

    @Sendable
    func detail(req: Request) async throws -> FileDTO {
        try await find(req).toDTO()
    }

    /// Persists the per-file manual-work (difficulty) level chosen in the
    /// print estimate section — same field the macOS app writes to
    /// `file.printParams.manualWorkLevel` in SwiftData.
    @Sendable
    func update(req: Request) async throws -> FileDTO {
        let file = try await find(req)
        let body = try req.content.decode(FileUpdateRequest.self)
        return try await Self.applyUpdate(body, to: file, on: req.db)
    }

    static func applyUpdate(_ body: FileUpdateRequest, to file: FileModel, on db: Database) async throws -> FileDTO {
        if body.manualWorkLevel != nil || body.actualPrintTimeSec != nil || body.actualFilamentGrams != nil {
            var params = file.printParams ?? PrintParamsDTO()
            if let level = body.manualWorkLevel { params.manualWorkLevel = level }
            if let time = body.actualPrintTimeSec { params.actualPrintTimeSec = time }
            if let grams = body.actualFilamentGrams { params.actualFilamentGrams = grams }
            file.printParams = params
        }
        try await file.save(on: db)
        return file.toDTO()
    }

    /// Accepts `?plateIndex=N` for multi-plate files (defaults to plate 0).
    @Sendable
    func estimate(req: Request) async throws -> PrintEstimate {
        let file = try await find(req)
        let query = try req.query.decode(EstimateQuery.self)
        return try await Self.fetchEstimate(file: file, query: query, on: req.db)
    }

    static func fetchEstimate(file: FileModel, query: EstimateQuery, on db: Database) async throws -> PrintEstimate {
        guard let stats = EstimateSupport.meshStats(for: file, plateIndex: query.plateIndex) else {
            throw Abort(.conflict, reason: "Pas de statistiques de maillage — lancez un scan d'abord")
        }
        let (printer, material, settings, manual) = try await EstimateSupport.inputs(query: query, on: db)
        return PrintEstimator.estimate(
            parsed: EstimateSupport.parserResult(from: stats),
            printer: printer, material: material,
            settings: settings, manualWork: manual
        )
    }

    // MARK: - Helpers

    private func find(_ req: Request) async throws -> FileModel {
        try await Self.find(id: requireFileID(req), on: req.db)
    }

    static func find(id: UUID, on db: Database) async throws -> FileModel {
        guard let model = try await FileModel.find(id, on: db) else {
            throw Abort(.notFound, reason: "Fichier introuvable")
        }
        return model
    }

    private func requireFileID(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("fileID", as: UUID.self) else {
            throw Abort(.notFound, reason: "Fichier introuvable")
        }
        return id
    }
```

- [ ] **Step 2: Write `FileMCPTools.swift`**

Create `Sources/PrintPlexServerApp/MCP/FileMCPTools.swift`:

```swift
import Vapor
import PrintPlexCore
import MCP

enum FileMCPTools {
    static let tools: [Tool] = [
        Tool(name: "list_files",
             description: "Liste tous les fichiers de la bibliothèque (pièces 3D, images, documents), optionnellement filtrés par type.",
             inputSchema: objectSchema(properties: [
                "kind": stringProp("Filtre par type (stl, threeMF, obj, step, other)"),
             ])),
        Tool(name: "list_unsorted_files",
             description: "Liste les fichiers qui ne sont rattachés à aucun projet.",
             inputSchema: objectSchema()),
        Tool(name: "get_file_stats",
             description: "Comptage des fichiers par type (STL, 3MF, OBJ, STEP, autres, non triés).",
             inputSchema: objectSchema()),
        Tool(name: "get_file",
             description: "Détail d'un fichier (métadonnées, statistiques de maillage, paramètres d'impression).",
             inputSchema: objectSchema(
                properties: ["fileId": stringProp("UUID du fichier")],
                required: ["fileId"])),
        Tool(name: "update_file",
             description: "Enregistre les données d'impression réelle/mesurée d'un fichier (niveau de travail manuel, temps réel en secondes, poids de filament réel en grammes) — prioritaires sur l'estimation géométrique.",
             inputSchema: objectSchema(
                properties: [
                    "fileId": stringProp("UUID du fichier"),
                    "manualWorkLevel": stringProp("Niveau de travail manuel (aucun, leger, modere, important)"),
                    "actualPrintTimeSec": intProp("Temps d'impression réel, en secondes"),
                    "actualFilamentGrams": numberProp("Poids de filament réel, en grammes"),
                ],
                required: ["fileId"])),
        Tool(name: "get_file_estimate",
             description: "Estimation d'impression pour une seule pièce (temps, filament, coût), à partir de ses statistiques de maillage.",
             inputSchema: objectSchema(
                properties: [
                    "fileId": stringProp("UUID du fichier"),
                    "plateIndex": intProp("Index de plateau pour un fichier multi-plateaux (défaut : 0)"),
                    "printerId": stringProp("UUID de l'imprimante"),
                    "materialId": stringProp("UUID du matériau"),
                    "manualWork": stringProp("Niveau de travail manuel"),
                ],
                required: ["fileId"])),
    ]

    static func call(_ name: String, _ arguments: [String: Value]?, app: Application) async throws -> CallTool.Result? {
        switch name {
        case "list_files":
            return try await toolResult(FileController.fetchIndex(kind: arguments?["kind"]?.stringValue, on: app.db))

        case "list_unsorted_files":
            return try await toolResult(FileController.fetchUnsorted(on: app.db))

        case "get_file_stats":
            return try await toolResult(FileController.fetchStats(on: app.db))

        case "get_file":
            let file = try await FileController.find(id: fileID(from: arguments), on: app.db)
            return try toolResult(file.toDTO())

        case "update_file":
            let id = try fileID(from: arguments)
            let body = try decodeArguments(FileUpdateRequest.self, from: arguments)
            let file = try await FileController.find(id: id, on: app.db)
            return try await toolResult(FileController.applyUpdate(body, to: file, on: app.db))

        case "get_file_estimate":
            let id = try fileID(from: arguments)
            let query = try decodeArguments(EstimateQuery.self, from: arguments)
            let file = try await FileController.find(id: id, on: app.db)
            return try await toolResult(FileController.fetchEstimate(file: file, query: query, on: app.db))

        default:
            return nil
        }
    }

    private static func fileID(from arguments: [String: Value]?) throws -> UUID {
        guard let raw = arguments?["fileId"]?.stringValue, let id = UUID(uuidString: raw) else {
            throw MCPToolError.invalidArguments("fileId manquant ou invalide")
        }
        return id
    }
}
```

- [ ] **Step 3: Register the group**

In `Sources/PrintPlexServerApp/MCP/MCPToolRegistry.swift`, add `FileMCPTools.tools` / `.call` as the second entry in each array (comma after the `ProjectMCPTools` line).

- [ ] **Step 4: Add the test**

In `Tests/PrintPlexServerAppTests/MCPTests.swift`, add:

```swift
    func testListFilesToolReturnsEmptyArrayWhenNoFiles() async throws {
        let res = try await callTool("list_files")
        XCTAssertEqual(res.status, .ok)
        XCTAssertFalse(res.body.string.contains("\"isError\":true"))
    }
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter MCPTests`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/PrintPlexServerApp/Controllers/FileController.swift Sources/PrintPlexServerApp/MCP/FileMCPTools.swift Sources/PrintPlexServerApp/MCP/MCPToolRegistry.swift Tests/PrintPlexServerAppTests/MCPTests.swift
git commit -m "feat: add Files MCP tools (list/unsorted/stats/get/update/estimate)"
```

---

### Task 5: Scan MCP tools

**Files:**
- Modify: `Sources/PrintPlexServerApp/Controllers/ScanController.swift`
- Create: `Sources/PrintPlexServerApp/MCP/ScanMCPTools.swift`
- Modify: `Sources/PrintPlexServerApp/MCP/MCPToolRegistry.swift`
- Modify: `Tests/PrintPlexServerAppTests/MCPTests.swift`

**Interfaces:**
- Produces: `ScanController.triggerScan(wait:app:)`, `.makeStatus(app:)`. (`events` — the SSE stream — is intentionally left untouched and **not** exposed as a tool; see Global Constraints.)

- [ ] **Step 1: Extract static helpers in `ScanController`**

In `Sources/PrintPlexServerApp/Controllers/ScanController.swift`, replace `trigger`, `status`, and the trailing `private func makeStatus` with:

```swift
    /// POST /api/scan — background by default; ?wait=true blocks until done
    /// (scan + mesh parsing), which is also what the tests rely on.
    @Sendable
    func trigger(req: Request) async throws -> ScanStatusResponse {
        let wait = (try? req.query.get(Bool.self, at: "wait")) ?? false
        return try await Self.triggerScan(wait: wait, app: req.application)
    }

    static func triggerScan(wait: Bool, app: Application) async throws -> ScanStatusResponse {
        let service = app.scanService
        if wait {
            // Caller explicitly asked to block until done — run at normal
            // priority so it doesn't sit needlessly behind other background work.
            await service.runScan()
        } else {
            // Fire-and-forget: this is exactly the kind of work that should
            // yield to anything request-driven, so it runs at the lowest priority.
            Task.detached(priority: .background) { await service.runScan() }
        }
        return try await makeStatus(app: app)
    }

    @Sendable
    func status(req: Request) async throws -> ScanStatusResponse {
        try await Self.makeStatus(app: req.application)
    }

    static func makeStatus(app: Application) async throws -> ScanStatusResponse {
        let state = await app.scanService.state()
        let projectCount = try await ProjectModel.query(on: app.db).count()
        let fileCount = try await FileModel.query(on: app.db).count()
        return ScanStatusResponse(
            isScanning: state.isScanning,
            lastScanDate: state.lastScanDate,
            lastScanProjects: state.lastScanProjects,
            lastScanFiles: state.lastScanFiles,
            projectCount: projectCount,
            fileCount: fileCount
        )
    }
```

(Leave the `events` method exactly as-is.)

- [ ] **Step 2: Write `ScanMCPTools.swift`**

Create `Sources/PrintPlexServerApp/MCP/ScanMCPTools.swift`:

```swift
import Vapor
import MCP

enum ScanMCPTools {
    static let tools: [Tool] = [
        Tool(name: "trigger_scan",
             description: "Déclenche un scan de la bibliothèque (détecte les fichiers/projets nouveaux, modifiés ou supprimés).",
             inputSchema: objectSchema(properties: [
                "wait": boolProp("Attendre la fin du scan avant de répondre (défaut : false, scan en arrière-plan)"),
             ])),
        Tool(name: "get_scan_status",
             description: "État du dernier scan (en cours ou non, date, nombre de projets/fichiers trouvés) et totaux actuels de la bibliothèque.",
             inputSchema: objectSchema()),
    ]

    static func call(_ name: String, _ arguments: [String: Value]?, app: Application) async throws -> CallTool.Result? {
        switch name {
        case "trigger_scan":
            let wait = arguments?["wait"]?.boolValue ?? false
            return try await toolResult(ScanController.triggerScan(wait: wait, app: app))
        case "get_scan_status":
            return try await toolResult(ScanController.makeStatus(app: app))
        default:
            return nil
        }
    }
}
```

- [ ] **Step 3: Register the group**

Add `ScanMCPTools.tools` / `.call` as the third entry in `MCPToolRegistry.swift`.

- [ ] **Step 4: Add the test**

```swift
    func testGetScanStatusToolReturnsStatus() async throws {
        let res = try await callTool("get_scan_status")
        XCTAssertEqual(res.status, .ok)
        XCTAssertTrue(res.body.string.contains("\"isScanning\""))
    }
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter MCPTests`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/PrintPlexServerApp/Controllers/ScanController.swift Sources/PrintPlexServerApp/MCP/ScanMCPTools.swift Sources/PrintPlexServerApp/MCP/MCPToolRegistry.swift Tests/PrintPlexServerAppTests/MCPTests.swift
git commit -m "feat: add Scan MCP tools (trigger_scan, get_scan_status)"
```

---

### Task 6: Libraries MCP tools

**Files:**
- Modify: `Sources/PrintPlexServerApp/Controllers/LibraryController.swift`
- Create: `Sources/PrintPlexServerApp/MCP/LibraryMCPTools.swift`
- Modify: `Sources/PrintPlexServerApp/MCP/MCPToolRegistry.swift`
- Modify: `Tests/PrintPlexServerAppTests/MCPTests.swift`

**Interfaces:**
- Produces: `LibraryController.fetchIndex(on:)`, `.createLibrary(_:app:)`, `.deleteLibrary(id:on:)`, `.browse(path:app:)`.

- [ ] **Step 1: Extract static helpers in `LibraryController`**

In `Sources/PrintPlexServerApp/Controllers/LibraryController.swift`, replace `index`, `create`, `delete`, `browse` with:

```swift
    @Sendable
    func index(req: Request) async throws -> [LibraryDTO] {
        try await Self.fetchIndex(on: req.db)
    }

    static func fetchIndex(on db: Database) async throws -> [LibraryDTO] {
        try await LibraryModel.query(on: db).sort(\.$sortOrder).all().map { $0.toDTO() }
    }

    @Sendable
    func create(req: Request) async throws -> LibraryDTO {
        let body = try req.content.decode(LibraryCreateRequest.self)
        return try await Self.createLibrary(body, app: req.application)
    }

    static func createLibrary(_ body: LibraryCreateRequest, app: Application) async throws -> LibraryDTO {
        let mediaPath = app.appConfig.mediaPath
        let relativePath = try validatedRelativePath(body.relativePath, mediaPath: mediaPath)

        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw Abort(.badRequest, reason: "Le nom de la bibliothèque ne peut pas être vide")
        }

        let absolutePath = relativePath.isEmpty ? mediaPath
            : URL(fileURLWithPath: mediaPath).appendingPathComponent(relativePath).standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDir), isDir.boolValue else {
            throw Abort(.badRequest, reason: "Ce dossier n'existe pas dans le répertoire média")
        }

        if try await LibraryModel.query(on: app.db)
            .filter(\.$relativePath == relativePath)
            .first() != nil {
            throw Abort(.conflict, reason: "Ce dossier est déjà une bibliothèque")
        }

        let maxOrder = try await LibraryModel.query(on: app.db).max(\.$sortOrder) ?? -1
        let model = LibraryModel(name: name, relativePath: relativePath, sortOrder: maxOrder + 1)
        try await model.save(on: app.db)

        // New library, empty results so far — worth a scan without making the
        // caller wait for it (mirrors the "Scanner maintenant" button).
        Task.detached(priority: .background) { await app.scanService.runScan() }

        return model.toDTO()
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("libraryID", as: UUID.self) else {
            throw Abort(.notFound, reason: "Bibliothèque introuvable")
        }
        try await Self.deleteLibrary(id: id, on: req.db)
        return .noContent
    }

    static func deleteLibrary(id: UUID, on db: Database) async throws {
        guard let model = try await LibraryModel.find(id, on: db) else {
            throw Abort(.notFound, reason: "Bibliothèque introuvable")
        }
        try await model.delete(on: db)
        // Projects/files that were under this folder stop being "seen" by the
        // next scan and get cleaned up by its usual stale-entry removal —
        // same mechanism that already handles files deleted from disk.
    }

    /// Lists subdirectories under `mediaPath/path`, for the folder-picker in
    /// the Settings UI (mirrors Plex's "browse for folder" dialog when adding
    /// a library). Only directories are listed — files aren't pickable.
    @Sendable
    func browse(req: Request) async throws -> BrowseResponse {
        let requested = (try? req.query.get(String.self, at: "path")) ?? ""
        return try Self.browse(path: requested, app: req.application)
    }

    static func browse(path requested: String, app: Application) throws -> BrowseResponse {
        let mediaPath = app.appConfig.mediaPath
        let relativePath = try validatedRelativePath(requested, mediaPath: mediaPath)
        let absolutePath = relativePath.isEmpty ? mediaPath
            : URL(fileURLWithPath: mediaPath).appendingPathComponent(relativePath).standardizedFileURL.path

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDir), isDir.boolValue else {
            throw Abort(.notFound, reason: "Ce dossier n'existe pas dans le répertoire média")
        }

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: absolutePath)) ?? []
        let directories = entries
            .filter { !$0.hasPrefix(".") }
            .filter { entry in
                var d: ObjCBool = false
                FileManager.default.fileExists(atPath: absolutePath + "/" + entry, isDirectory: &d)
                return d.boolValue
            }
            .sorted()

        let parentPath: String?
        if relativePath.isEmpty {
            parentPath = nil
        } else {
            let components = relativePath.split(separator: "/")
            parentPath = components.count > 1 ? components.dropLast().joined(separator: "/") : ""
        }

        return BrowseResponse(path: relativePath, parentPath: parentPath, directories: directories)
    }
```

(Leave `static func validatedRelativePath` at the bottom of the file exactly as-is — it's already a pure static helper.)

- [ ] **Step 2: Write `LibraryMCPTools.swift`**

Create `Sources/PrintPlexServerApp/MCP/LibraryMCPTools.swift`:

```swift
import Vapor
import PrintPlexCore
import MCP

enum LibraryMCPTools {
    static let tools: [Tool] = [
        Tool(name: "list_libraries",
             description: "Liste les bibliothèques (dossiers scannés sous le répertoire média).",
             inputSchema: objectSchema()),
        Tool(name: "create_library",
             description: "Ajoute un nouveau dossier comme bibliothèque scannée, et déclenche un scan.",
             inputSchema: objectSchema(
                properties: [
                    "name": stringProp("Nom de la bibliothèque"),
                    "relativePath": stringProp("Chemin relatif au répertoire média (chaîne vide pour la racine)"),
                ],
                required: ["name", "relativePath"])),
        Tool(name: "browse_library",
             description: "Liste les sous-dossiers d'un chemin sous le répertoire média — pour choisir un dossier à ajouter comme bibliothèque.",
             inputSchema: objectSchema(properties: [
                "path": stringProp("Chemin relatif à parcourir (défaut : racine du répertoire média)"),
             ])),
        Tool(name: "delete_library",
             description: "Supprime une bibliothèque (ne supprime pas les fichiers sur le disque — ils cessent juste d'être scannés).",
             inputSchema: objectSchema(
                properties: ["libraryId": stringProp("UUID de la bibliothèque")],
                required: ["libraryId"]),
             annotations: .init(destructiveHint: true)
        ),
    ]

    static func call(_ name: String, _ arguments: [String: Value]?, app: Application) async throws -> CallTool.Result? {
        switch name {
        case "list_libraries":
            return try await toolResult(LibraryController.fetchIndex(on: app.db))

        case "create_library":
            let body = try decodeArguments(LibraryCreateRequest.self, from: arguments)
            return try await toolResult(LibraryController.createLibrary(body, app: app))

        case "browse_library":
            return try toolResult(LibraryController.browse(path: arguments?["path"]?.stringValue ?? "", app: app))

        case "delete_library":
            guard let raw = arguments?["libraryId"]?.stringValue, let id = UUID(uuidString: raw) else {
                throw MCPToolError.invalidArguments("libraryId manquant ou invalide")
            }
            try await LibraryController.deleteLibrary(id: id, on: app.db)
            return toolSuccess("Bibliothèque supprimée.")

        default:
            return nil
        }
    }
}
```

- [ ] **Step 3: Register the group**

Add `LibraryMCPTools.tools` / `.call` as the fourth entry in `MCPToolRegistry.swift`.

- [ ] **Step 4: Add the test**

```swift
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
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter MCPTests`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/PrintPlexServerApp/Controllers/LibraryController.swift Sources/PrintPlexServerApp/MCP/LibraryMCPTools.swift Sources/PrintPlexServerApp/MCP/MCPToolRegistry.swift Tests/PrintPlexServerAppTests/MCPTests.swift
git commit -m "feat: add Libraries MCP tools (list/create/browse/delete)"
```

---

### Task 7: Printers MCP tools

**Files:**
- Modify: `Sources/PrintPlexServerApp/Controllers/PrinterController.swift`
- Create: `Sources/PrintPlexServerApp/MCP/PrinterMCPTools.swift`
- Modify: `Sources/PrintPlexServerApp/MCP/MCPToolRegistry.swift`
- Modify: `Tests/PrintPlexServerAppTests/MCPTests.swift`

**Interfaces:**
- Produces: `PrinterController.fetchIndex(on:)`, `.createPrinter(_:on:)`, `.applyUpdate(_:to:on:)`, `.deletePrinter(_:on:)`, `.find(id:on:) -> PrinterModel`.

- [ ] **Step 1: Extract static helpers in `PrinterController`**

In `Sources/PrintPlexServerApp/Controllers/PrinterController.swift`, replace `index`, `create`, `update`, `delete`, and the trailing `private func find` with:

```swift
    @Sendable
    func index(req: Request) async throws -> [PrinterProfile] {
        try await Self.fetchIndex(on: req.db)
    }

    static func fetchIndex(on db: Database) async throws -> [PrinterProfile] {
        try await PrinterModel.query(on: db).sort(\.$sortOrder).all().map { $0.toDTO() }
    }

    @Sendable
    func create(req: Request) async throws -> PrinterProfile {
        let body = try req.content.decode(PrinterUpsertRequest.self)
        return try await Self.createPrinter(body, on: req.db)
    }

    static func createPrinter(_ body: PrinterUpsertRequest, on db: Database) async throws -> PrinterProfile {
        let maxOrder = try await PrinterModel.query(on: db).max(\.$sortOrder) ?? -1

        let model = PrinterModel()
        model.id = UUID()
        model.name = body.name
        model.buildX = body.buildX
        model.buildY = body.buildY
        model.buildZ = body.buildZ
        model.perimeterSpeedMMPS = body.perimeterSpeedMMPS
        model.infillSpeedMMPS = body.infillSpeedMMPS
        model.nozzleDiameterMM = body.nozzleDiameterMM
        model.defaultLayerHeightMM = body.defaultLayerHeightMM
        model.supportsPercent = body.supportsPercent
        model.purgePercent = body.purgePercent
        model.speedEfficiency = body.speedEfficiency
        model.sortOrder = maxOrder + 1
        try await model.save(on: db)
        return model.toDTO()
    }

    @Sendable
    func update(req: Request) async throws -> PrinterProfile {
        let model = try await find(req)
        let body = try req.content.decode(PrinterUpdateRequest.self)
        return try await Self.applyUpdate(body, to: model, on: req.db)
    }

    static func applyUpdate(_ body: PrinterUpdateRequest, to model: PrinterModel, on db: Database) async throws -> PrinterProfile {
        if let v = body.name { model.name = v }
        if let v = body.buildX { model.buildX = v }
        if let v = body.buildY { model.buildY = v }
        if let v = body.buildZ { model.buildZ = v }
        if let v = body.perimeterSpeedMMPS { model.perimeterSpeedMMPS = v }
        if let v = body.infillSpeedMMPS { model.infillSpeedMMPS = v }
        if let v = body.nozzleDiameterMM { model.nozzleDiameterMM = v }
        if let v = body.defaultLayerHeightMM { model.defaultLayerHeightMM = v }
        if let v = body.supportsPercent { model.supportsPercent = v }
        if let v = body.purgePercent { model.purgePercent = v }
        if let v = body.speedEfficiency { model.speedEfficiency = v }
        try await model.save(on: db)
        return model.toDTO()
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let model = try await find(req)
        try await Self.deletePrinter(model, on: req.db)
        return .noContent
    }

    static func deletePrinter(_ model: PrinterModel, on db: Database) async throws {
        try await model.delete(on: db)
    }

    private func find(_ req: Request) async throws -> PrinterModel {
        try await Self.find(id: requirePrinterID(req), on: req.db)
    }

    static func find(id: UUID, on db: Database) async throws -> PrinterModel {
        guard let model = try await PrinterModel.find(id, on: db) else {
            throw Abort(.notFound, reason: "Imprimante introuvable")
        }
        return model
    }

    private func requirePrinterID(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("printerID", as: UUID.self) else {
            throw Abort(.notFound, reason: "Imprimante introuvable")
        }
        return id
    }
```

- [ ] **Step 2: Write `PrinterMCPTools.swift`**

Create `Sources/PrintPlexServerApp/MCP/PrinterMCPTools.swift`:

```swift
import Vapor
import PrintPlexCore
import MCP

enum PrinterMCPTools {
    private static let upsertProperties: [String: Value] = [
        "name": stringProp("Nom de l'imprimante"),
        "buildX": numberProp("Largeur du plateau, en mm"),
        "buildY": numberProp("Profondeur du plateau, en mm"),
        "buildZ": numberProp("Hauteur du plateau, en mm"),
        "perimeterSpeedMMPS": numberProp("Vitesse de périmètre, en mm/s"),
        "infillSpeedMMPS": numberProp("Vitesse de remplissage, en mm/s"),
        "nozzleDiameterMM": numberProp("Diamètre de buse, en mm"),
        "defaultLayerHeightMM": numberProp("Hauteur de couche par défaut, en mm"),
        "supportsPercent": numberProp("Surcoût de temps pour les supports, en %"),
        "purgePercent": numberProp("Surcoût de temps pour les purges, en %"),
        "speedEfficiency": numberProp("Facteur d'efficacité de vitesse réelle (0-1)"),
    ]

    static let tools: [Tool] = [
        Tool(name: "list_printers",
             description: "Liste les profils d'imprimante configurés.",
             inputSchema: objectSchema()),
        Tool(name: "create_printer",
             description: "Ajoute un nouveau profil d'imprimante.",
             inputSchema: objectSchema(
                properties: upsertProperties,
                required: Array(upsertProperties.keys))),
        Tool(name: "update_printer",
             description: "Met à jour un profil d'imprimante existant. Seuls les champs fournis sont modifiés.",
             inputSchema: objectSchema(
                properties: upsertProperties.merging(["printerId": stringProp("UUID de l'imprimante")]) { _, new in new },
                required: ["printerId"])),
        Tool(name: "delete_printer",
             description: "Supprime un profil d'imprimante.",
             inputSchema: objectSchema(
                properties: ["printerId": stringProp("UUID de l'imprimante")],
                required: ["printerId"]),
             annotations: .init(destructiveHint: true)
        ),
    ]

    static func call(_ name: String, _ arguments: [String: Value]?, app: Application) async throws -> CallTool.Result? {
        switch name {
        case "list_printers":
            return try await toolResult(PrinterController.fetchIndex(on: app.db))

        case "create_printer":
            let body = try decodeArguments(PrinterUpsertRequest.self, from: arguments)
            return try await toolResult(PrinterController.createPrinter(body, on: app.db))

        case "update_printer":
            let id = try printerID(from: arguments)
            let body = try decodeArguments(PrinterUpdateRequest.self, from: arguments)
            let model = try await PrinterController.find(id: id, on: app.db)
            return try await toolResult(PrinterController.applyUpdate(body, to: model, on: app.db))

        case "delete_printer":
            let id = try printerID(from: arguments)
            let model = try await PrinterController.find(id: id, on: app.db)
            try await PrinterController.deletePrinter(model, on: app.db)
            return toolSuccess("Imprimante supprimée.")

        default:
            return nil
        }
    }

    private static func printerID(from arguments: [String: Value]?) throws -> UUID {
        guard let raw = arguments?["printerId"]?.stringValue, let id = UUID(uuidString: raw) else {
            throw MCPToolError.invalidArguments("printerId manquant ou invalide")
        }
        return id
    }
}
```

Note: `create_printer`'s schema marks every printer field required (matches `PrinterUpsertRequest`, whose fields are all non-optional `Double`/`String`) — `update_printer` reuses the same property definitions but only requires `printerId` (matches `PrinterUpdateRequest`, whose fields are all optional).

- [ ] **Step 3: Register the group**

Add `PrinterMCPTools.tools` / `.call` as the fifth entry in `MCPToolRegistry.swift`.

- [ ] **Step 4: Add the test**

```swift
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
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter MCPTests`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/PrintPlexServerApp/Controllers/PrinterController.swift Sources/PrintPlexServerApp/MCP/PrinterMCPTools.swift Sources/PrintPlexServerApp/MCP/MCPToolRegistry.swift Tests/PrintPlexServerAppTests/MCPTests.swift
git commit -m "feat: add Printers MCP tools (list/create/update/delete)"
```

---

### Task 8: Materials MCP tools

**Files:**
- Modify: `Sources/PrintPlexServerApp/Controllers/MaterialController.swift`
- Create: `Sources/PrintPlexServerApp/MCP/MaterialMCPTools.swift`
- Modify: `Sources/PrintPlexServerApp/MCP/MCPToolRegistry.swift`
- Modify: `Tests/PrintPlexServerAppTests/MCPTests.swift`

**Interfaces:**
- Produces: `MaterialController.fetchIndex(on:)`, `.applyUpdate(_:id:on:)`.

- [ ] **Step 1: Extract static helpers in `MaterialController`**

Replace the whole controller body with:

```swift
    @Sendable
    func index(req: Request) async throws -> [PrintMaterial] {
        try await Self.fetchIndex(on: req.db)
    }

    static func fetchIndex(on db: Database) async throws -> [PrintMaterial] {
        try await MaterialModel.query(on: db).sort(\.$sortOrder).all().map { $0.toDTO() }
    }

    @Sendable
    func update(req: Request) async throws -> PrintMaterial {
        guard let id = req.parameters.get("materialID", as: UUID.self) else {
            throw Abort(.notFound, reason: "Matériau introuvable")
        }
        let body = try req.content.decode(MaterialUpdateRequest.self)
        return try await Self.applyUpdate(body, id: id, on: req.db)
    }

    static func applyUpdate(_ body: MaterialUpdateRequest, id: UUID, on db: Database) async throws -> PrintMaterial {
        guard let model = try await MaterialModel.find(id, on: db) else {
            throw Abort(.notFound, reason: "Matériau introuvable")
        }
        guard body.pricePerKg > 0 else {
            throw Abort(.badRequest, reason: "Le prix doit être positif")
        }
        model.pricePerKg = body.pricePerKg
        try await model.save(on: db)
        return model.toDTO()
    }
```

- [ ] **Step 2: Write `MaterialMCPTools.swift`**

Create `Sources/PrintPlexServerApp/MCP/MaterialMCPTools.swift`:

```swift
import Vapor
import PrintPlexCore
import MCP

enum MaterialMCPTools {
    static let tools: [Tool] = [
        Tool(name: "list_materials",
             description: "Liste le catalogue de matériaux (nom, prix au kg).",
             inputSchema: objectSchema()),
        Tool(name: "update_material",
             description: "Met à jour le prix au kg d'un matériau.",
             inputSchema: objectSchema(
                properties: [
                    "materialId": stringProp("UUID du matériau"),
                    "pricePerKg": numberProp("Prix au kg, en euros (doit être positif)"),
                ],
                required: ["materialId", "pricePerKg"])),
    ]

    static func call(_ name: String, _ arguments: [String: Value]?, app: Application) async throws -> CallTool.Result? {
        switch name {
        case "list_materials":
            return try await toolResult(MaterialController.fetchIndex(on: app.db))

        case "update_material":
            guard let raw = arguments?["materialId"]?.stringValue, let id = UUID(uuidString: raw) else {
                throw MCPToolError.invalidArguments("materialId manquant ou invalide")
            }
            let body = try decodeArguments(MaterialUpdateRequest.self, from: arguments)
            return try await toolResult(MaterialController.applyUpdate(body, id: id, on: app.db))

        default:
            return nil
        }
    }
}
```

- [ ] **Step 3: Register the group**

Add `MaterialMCPTools.tools` / `.call` as the sixth entry in `MCPToolRegistry.swift`.

- [ ] **Step 4: Add the test**

```swift
    func testListMaterialsToolReturnsSeededCatalog() async throws {
        let res = try await callTool("list_materials")
        XCTAssertEqual(res.status, .ok)
        XCTAssertFalse(res.body.string.contains("\"isError\":true"))
        // seedReferenceDataIfNeeded() seeds PrintMaterial.defaults at boot.
        XCTAssertTrue(res.body.string.contains("\"pricePerKg\""))
    }
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter MCPTests`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/PrintPlexServerApp/Controllers/MaterialController.swift Sources/PrintPlexServerApp/MCP/MaterialMCPTools.swift Sources/PrintPlexServerApp/MCP/MCPToolRegistry.swift Tests/PrintPlexServerAppTests/MCPTests.swift
git commit -m "feat: add Materials MCP tools (list/update)"
```

---

### Task 9: Settings MCP tools

**Files:**
- Modify: `Sources/PrintPlexServerApp/Controllers/SettingsController.swift`
- Create: `Sources/PrintPlexServerApp/MCP/SettingsMCPTools.swift`
- Modify: `Sources/PrintPlexServerApp/MCP/MCPToolRegistry.swift`
- Modify: `Tests/PrintPlexServerAppTests/MCPTests.swift`

**Interfaces:**
- Produces: `SettingsController.fetchOverview(app:)`, `.fetchShopifySettings(on:)`, `.applyShopifyUpdate(_:app:)`.

- [ ] **Step 1: Extract static helpers in `SettingsController`**

Replace `overview`, `shopify`, `updateShopify` with (leave `updateScan` untouched — it's already a thin `req.application.scanService` call with no extraction needed):

```swift
    @Sendable
    func overview(req: Request) async throws -> SettingsOverview {
        try await Self.fetchOverview(app: req.application)
    }

    static func fetchOverview(app: Application) async throws -> SettingsOverview {
        let scanSettings = await app.scanService.currentScanSettings()
        let config = app.appConfig

        var storeDomain = ""
        var configured = false
        var productCount = 0
        var lastSyncDate: Date?
        var syncError: String?
        if let cache = app.shopifyCache {
            let creds = await cache.credentials
            storeDomain = creds.storeDomain
            configured = creds.isConfigured
            productCount = await cache.products.count
            lastSyncDate = await cache.lastSyncDate
            syncError = await cache.syncError
        }

        return SettingsOverview(
            serverVersion: printPlexServerVersion,
            mediaPath: config.mediaPath,
            dataPath: config.dataPath,
            autoScanEnabled: scanSettings.autoScanEnabled,
            scanIntervalMinutes: scanSettings.scanIntervalMinutes,
            shopifyStoreDomain: storeDomain,
            shopifyConfigured: configured,
            shopifyProductCount: productCount,
            shopifyLastSyncDate: lastSyncDate,
            shopifySyncError: syncError
        )
    }

    @Sendable
    func updateScan(req: Request) async throws -> ScanSettings {
        let body = try req.content.decode(ScanSettingsUpdateRequest.self)
        return try await req.application.scanService.updateScanSettings(
            autoScanEnabled: body.autoScanEnabled,
            scanIntervalMinutes: body.scanIntervalMinutes
        )
    }

    /// Includes the plaintext access token so the edit form can be prefilled —
    /// same trust model as the macOS app, which stores it unencrypted in
    /// UserDefaults. Acceptable for a personal server on a private network.
    @Sendable
    func shopify(req: Request) async throws -> ShopifySettingsResponse {
        try await Self.fetchShopifySettings(on: req.db)
    }

    static func fetchShopifySettings(on db: Database) async throws -> ShopifySettingsResponse {
        guard let row = try await AppSettingsModel.find(AppSettingsModel.singletonID, on: db) else {
            return ShopifySettingsResponse(storeDomain: "", accessToken: "", configured: false)
        }
        let creds = ShopifyCredentials(storeDomain: row.shopifyStoreDomain ?? "",
                                       accessToken: row.shopifyAccessToken ?? "")
        return ShopifySettingsResponse(storeDomain: creds.storeDomain,
                                       accessToken: creds.accessToken,
                                       configured: creds.isConfigured)
    }

    @Sendable
    func updateShopify(req: Request) async throws -> ShopifySettingsResponse {
        let body = try req.content.decode(ShopifySettingsUpdateRequest.self)
        return try await Self.applyShopifyUpdate(body, app: req.application)
    }

    static func applyShopifyUpdate(_ body: ShopifySettingsUpdateRequest, app: Application) async throws -> ShopifySettingsResponse {
        let credentials = ShopifyCredentials(storeDomain: body.storeDomain, accessToken: body.accessToken)

        guard let row = try await AppSettingsModel.find(AppSettingsModel.singletonID, on: app.db) else {
            throw Abort(.internalServerError, reason: "Ligne de réglages absente")
        }
        row.shopifyStoreDomain = credentials.storeDomain
        row.shopifyAccessToken = credentials.accessToken
        try await row.save(on: app.db)

        if let cache = app.shopifyCache {
            await cache.updateCredentials(credentials)
        } else if credentials.isConfigured {
            app.shopifyCache = ShopifyCache(credentials: credentials)
        }

        return ShopifySettingsResponse(storeDomain: credentials.storeDomain,
                                       accessToken: credentials.accessToken,
                                       configured: credentials.isConfigured)
    }
```

- [ ] **Step 2: Write `SettingsMCPTools.swift`**

Create `Sources/PrintPlexServerApp/MCP/SettingsMCPTools.swift`. `get_shopify_settings` deliberately returns only `storeDomain`/`configured` — never the plaintext token — via a dedicated summary type (see Global Constraints):

```swift
import Vapor
import PrintPlexCore
import MCP

/// A `configured`/`storeDomain`-only view of Shopify settings for MCP —
/// unlike the dashboard's own settings screen (which needs the plaintext
/// token to prefill an edit form for a human), an agent never needs to read
/// the raw secret back.
struct ShopifySettingsSummary: Encodable {
    var storeDomain: String
    var configured: Bool
}

enum SettingsMCPTools {
    static let tools: [Tool] = [
        Tool(name: "get_settings",
             description: "Réglages généraux du serveur (chemins média/données, cadence de scan, état Shopify).",
             inputSchema: objectSchema()),
        Tool(name: "update_scan_settings",
             description: "Met à jour la cadence de scan automatique.",
             inputSchema: objectSchema(properties: [
                "autoScanEnabled": boolProp("Activer le scan automatique périodique"),
                "scanIntervalMinutes": intProp("Intervalle entre deux scans automatiques, en minutes"),
             ])),
        Tool(name: "get_shopify_settings",
             description: "Domaine de la boutique Shopify configurée et si elle est prête à l'emploi (le jeton d'accès n'est jamais renvoyé).",
             inputSchema: objectSchema()),
        Tool(name: "update_shopify_settings",
             description: "Configure les identifiants Shopify (domaine de boutique et jeton d'accès).",
             inputSchema: objectSchema(
                properties: [
                    "storeDomain": stringProp("Domaine de la boutique Shopify (ex: maboutique.myshopify.com)"),
                    "accessToken": stringProp("Jeton d'accès API Shopify"),
                ],
                required: ["storeDomain", "accessToken"])),
    ]

    static func call(_ name: String, _ arguments: [String: Value]?, app: Application) async throws -> CallTool.Result? {
        switch name {
        case "get_settings":
            return try await toolResult(SettingsController.fetchOverview(app: app))

        case "update_scan_settings":
            let body = try decodeArguments(ScanSettingsUpdateRequest.self, from: arguments)
            return try await toolResult(app.scanService.updateScanSettings(
                autoScanEnabled: body.autoScanEnabled, scanIntervalMinutes: body.scanIntervalMinutes))

        case "get_shopify_settings":
            let settings = try await SettingsController.fetchShopifySettings(on: app.db)
            return try toolResult(ShopifySettingsSummary(storeDomain: settings.storeDomain, configured: settings.configured))

        case "update_shopify_settings":
            let body = try decodeArguments(ShopifySettingsUpdateRequest.self, from: arguments)
            return try await toolResult(SettingsController.applyShopifyUpdate(body, app: app))

        default:
            return nil
        }
    }
}
```

- [ ] **Step 3: Register the group**

Add `SettingsMCPTools.tools` / `.call` as the seventh entry in `MCPToolRegistry.swift`.

- [ ] **Step 4: Add the test**

```swift
    func testGetShopifySettingsToolNeverReturnsAccessToken() async throws {
        // Directly seed a token via the settings row, bypassing the API, so
        // this test would fail loudly if the redaction were ever removed.
        let row = try await AppSettingsModel.find(AppSettingsModel.singletonID, on: app.db)!
        row.shopifyStoreDomain = "maboutique.myshopify.com"
        row.shopifyAccessToken = "shpat_supersecret"
        try await row.save(on: app.db)

        let res = try await callTool("get_shopify_settings")
        XCTAssertEqual(res.status, .ok)
        XCTAssertFalse(res.body.string.contains("shpat_supersecret"))
        XCTAssertTrue(res.body.string.contains("maboutique.myshopify.com"))
    }
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter MCPTests`
Expected: all tests pass — in particular, the token-redaction test confirms the security call made in this task.

- [ ] **Step 6: Commit**

```bash
git add Sources/PrintPlexServerApp/Controllers/SettingsController.swift Sources/PrintPlexServerApp/MCP/SettingsMCPTools.swift Sources/PrintPlexServerApp/MCP/MCPToolRegistry.swift Tests/PrintPlexServerAppTests/MCPTests.swift
git commit -m "feat: add Settings MCP tools (get/update scan+shopify, token redacted)"
```

---

### Task 10: Shopify MCP tools

**Files:**
- Modify: `Sources/PrintPlexServerApp/Controllers/ShopifyController.swift`
- Create: `Sources/PrintPlexServerApp/MCP/ShopifyMCPTools.swift`
- Modify: `Sources/PrintPlexServerApp/MCP/MCPToolRegistry.swift`
- Modify: `Tests/PrintPlexServerAppTests/MCPTests.swift`

**Interfaces:**
- Produces: `ShopifyController.fetchProducts(app:)`, `.createProduct(_:app:)`, `.syncShopify(app:)`.

- [ ] **Step 1: Extract static helpers in `ShopifyController`**

Replace `products`, `createProduct`, `resolveImages`, `sync`, `cache` (leave `abortify` untouched — already static) with:

```swift
    @Sendable
    func products(req: Request) async throws -> [ShopifyProduct] {
        try await Self.fetchProducts(app: req.application)
    }

    static func fetchProducts(app: Application) async throws -> [ShopifyProduct] {
        do {
            return try await cache(app).productsSyncingIfNeeded()
        } catch {
            throw abortify(error)
        }
    }

    @Sendable
    func createProduct(req: Request) async throws -> ShopifyProduct {
        let body = try req.content.decode(ShopifyCreateProductRequest.self)
        return try await Self.createProduct(body, app: req.application)
    }

    static func createProduct(_ body: ShopifyCreateProductRequest, app: Application) async throws -> ShopifyProduct {
        guard !body.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "Le titre est obligatoire")
        }
        let images = try await resolveImages(fileIds: body.imageFileIds ?? [], app: app)
        do {
            return try await cache(app).createProduct(
                title: body.title, bodyHtml: body.bodyHtml, vendor: body.vendor,
                productType: body.productType, tags: body.tags,
                variants: body.variants ?? [], metafields: body.metafields ?? [],
                images: images, collections: body.collections ?? [],
                category: body.category, categoryMetafields: body.categoryMetafields ?? []
            )
        } catch {
            throw abortify(error)
        }
    }

    /// Reads each named project file straight off disk and base64-encodes it —
    /// a file that's since vanished or moved outside the media root is just
    /// skipped rather than failing the whole product creation over one photo.
    private static func resolveImages(fileIds: [UUID], app: Application) async throws -> [ShopifyImageInput] {
        guard !fileIds.isEmpty else { return [] }
        let config = app.appConfig
        var images: [ShopifyImageInput] = []
        for fileId in fileIds {
            guard let file = try await FileModel.find(fileId, on: app.db),
                  let path = try? MediaPath.safePath(for: file, in: config),
                  let data = FileManager.default.contents(atPath: path) else { continue }
            images.append(ShopifyImageInput(
                attachment: data.base64EncodedString(),
                filename: "\(file.fileName).\(file.fileExtension)"
            ))
        }
        return images
    }

    @Sendable
    func sync(req: Request) async throws -> ShopifySyncResponse {
        try await Self.syncShopify(app: req.application)
    }

    static func syncShopify(app: Application) async throws -> ShopifySyncResponse {
        let cache = try cache(app)
        do {
            let count = try await cache.sync()
            return ShopifySyncResponse(productCount: count, lastSyncDate: await cache.lastSyncDate)
        } catch {
            throw abortify(error)
        }
    }

    private static func cache(_ app: Application) throws -> ShopifyCache {
        guard let cache = app.shopifyCache else {
            throw Abort(.serviceUnavailable, reason: "Shopify non configuré (SHOPIFY_STORE_DOMAIN / SHOPIFY_ACCESS_TOKEN)")
        }
        return cache
    }
```

- [ ] **Step 2: Write `ShopifyMCPTools.swift`**

Create `Sources/PrintPlexServerApp/MCP/ShopifyMCPTools.swift`. `create_shopify_product`'s advertised schema covers the common top-level fields only (title/description/vendor/type/tags/photos) — an agent rarely needs to set Shopify's nested variant/metafield/collection/category matrices, and `ShopifyCreateProductRequest`'s decode still accepts them if ever passed, since unlisted optional fields simply stay nil:

```swift
import Vapor
import PrintPlexCore
import MCP

enum ShopifyMCPTools {
    static let tools: [Tool] = [
        Tool(name: "list_shopify_products",
             description: "Liste les produits Shopify synchronisés (déclenche une synchronisation si nécessaire).",
             inputSchema: objectSchema()),
        Tool(name: "create_shopify_product",
             description: "Crée un nouveau produit Shopify à partir d'un titre, d'une description, et éventuellement de photos issues de fichiers projet locaux.",
             inputSchema: objectSchema(
                properties: [
                    "title": stringProp("Titre du produit (obligatoire)"),
                    "bodyHtml": stringProp("Description HTML"),
                    "vendor": stringProp("Marque/fournisseur"),
                    "productType": stringProp("Type de produit"),
                    "tags": stringProp("Tags, séparés par des virgules"),
                    "imageFileIds": arrayProp("UUIDs de fichiers projet locaux à joindre comme photos"),
                ],
                required: ["title"])),
        Tool(name: "sync_shopify",
             description: "Force une synchronisation complète avec Shopify.",
             inputSchema: objectSchema()),
    ]

    static func call(_ name: String, _ arguments: [String: Value]?, app: Application) async throws -> CallTool.Result? {
        switch name {
        case "list_shopify_products":
            return try await toolResult(ShopifyController.fetchProducts(app: app))

        case "create_shopify_product":
            let body = try decodeArguments(ShopifyCreateProductRequest.self, from: arguments)
            return try await toolResult(ShopifyController.createProduct(body, app: app))

        case "sync_shopify":
            return try await toolResult(ShopifyController.syncShopify(app: app))

        default:
            return nil
        }
    }
}
```

- [ ] **Step 3: Register the group**

Add `ShopifyMCPTools.tools` / `.call` as the eighth entry in `MCPToolRegistry.swift`.

- [ ] **Step 4: Add the test**

```swift
    func testListShopifyProductsToolReturnsServiceUnavailableWhenNotConfigured() async throws {
        // SHOPIFY_STORE_DOMAIN/ACCESS_TOKEN are empty in setUp(), so no
        // ShopifyCache is created at boot — this must surface as a tool
        // error, not a crash.
        let res = try await callTool("list_shopify_products")
        XCTAssertEqual(res.status, .ok)
        XCTAssertTrue(res.body.string.contains("\"isError\":true"))
        XCTAssertTrue(res.body.string.contains("Shopify non configuré"))
    }
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter MCPTests`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/PrintPlexServerApp/Controllers/ShopifyController.swift Sources/PrintPlexServerApp/MCP/ShopifyMCPTools.swift Sources/PrintPlexServerApp/MCP/MCPToolRegistry.swift Tests/PrintPlexServerAppTests/MCPTests.swift
git commit -m "feat: add Shopify MCP tools (list/create/sync)"
```

---

### Task 11: ForgeCore MCP tool

**Files:**
- Modify: `Sources/PrintPlexServerApp/Controllers/ForgeCoreController.swift`
- Create: `Sources/PrintPlexServerApp/MCP/ForgeCoreMCPTools.swift`
- Modify: `Sources/PrintPlexServerApp/MCP/MCPToolRegistry.swift`
- Modify: `Tests/PrintPlexServerAppTests/MCPTests.swift`

**Interfaces:**
- Produces: `ForgeCoreController.fetchPending(on:)`. (`importResult` — the relay's own internal callback protocol, complete with base64 photo payloads — is intentionally left untouched and not exposed as a tool; it's not a user-facing action an agent would take.)

- [ ] **Step 1: Extract a static helper in `ForgeCoreController`**

Replace `pending` with:

```swift
    @Sendable
    func pending(req: Request) async throws -> [ForgeCorePendingProject] {
        try await Self.fetchPending(on: req.db)
    }

    static func fetchPending(on db: Database) async throws -> [ForgeCorePendingProject] {
        // Compared against a local `let`, not an inline string literal —
        // mirrors `\.$kindRaw == kindRaw` in FileController rather than
        // `\.$field == "literal"`, which has tripped Fluent's key-path type
        // inference before.
        let pendingStatus = "pending"
        let models = try await ProjectModel.query(on: db)
            .filter(\.$sourceScrapeStatus == pendingStatus)
            .all()
        return models.compactMap { model in
            guard let id = model.id, let url = model.sourceUrl else { return nil }
            return ForgeCorePendingProject(id: id, name: model.name, sourceUrl: url)
        }
    }
```

- [ ] **Step 2: Write `ForgeCoreMCPTools.swift`**

Create `Sources/PrintPlexServerApp/MCP/ForgeCoreMCPTools.swift`:

```swift
import Vapor
import MCP

enum ForgeCoreMCPTools {
    static let tools: [Tool] = [
        Tool(name: "get_forgecore_pending",
             description: "Liste les projets en attente de scraping ForgeCore (statut de scrape 'pending').",
             inputSchema: objectSchema()),
    ]

    static func call(_ name: String, _ arguments: [String: Value]?, app: Application) async throws -> CallTool.Result? {
        switch name {
        case "get_forgecore_pending":
            return try await toolResult(ForgeCoreController.fetchPending(on: app.db))
        default:
            return nil
        }
    }
}
```

- [ ] **Step 3: Register the group**

Add `ForgeCoreMCPTools.tools` / `.call` as the ninth and final entry in `MCPToolRegistry.swift`.

- [ ] **Step 4: Add the test**

```swift
    func testGetForgecorePendingToolReturnsEmptyArrayWhenNothingPending() async throws {
        let res = try await callTool("get_forgecore_pending")
        XCTAssertEqual(res.status, .ok)
        XCTAssertFalse(res.body.string.contains("\"isError\":true"))
    }
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter MCPTests`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/PrintPlexServerApp/Controllers/ForgeCoreController.swift Sources/PrintPlexServerApp/MCP/ForgeCoreMCPTools.swift Sources/PrintPlexServerApp/MCP/MCPToolRegistry.swift Tests/PrintPlexServerAppTests/MCPTests.swift
git commit -m "feat: add ForgeCore MCP tool (get_forgecore_pending)"
```

---

### Task 12: End-to-end write test, README docs, manual smoke test

**Files:**
- Modify: `Tests/PrintPlexServerAppTests/MCPTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 2–11 (`allTools` now lists every tool from every group).

- [ ] **Step 1: Write an end-to-end write test covering the full request path**

In `Tests/PrintPlexServerAppTests/MCPTests.swift`, add (this exercises auth + `tools/list` completeness + a real write persisted to the DB, the "one read tool, one write tool" coverage called for in the spec):

```swift
    func testToolsListIncludesEveryRegisteredGroup() async throws {
        try await app.test(.POST, "api/mcp", beforeRequest: { req in
            req.headers.replaceOrAdd(name: "Content-Type", value: "application/json")
            req.headers.replaceOrAdd(name: "Accept", value: "application/json")
            req.body = try rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]])
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            for name in ["list_projects", "list_files", "trigger_scan", "list_libraries",
                         "list_printers", "list_materials", "get_settings",
                         "list_shopify_products", "get_forgecore_pending"] {
                XCTAssertTrue(res.body.string.contains("\"\(name)\""), "missing tool: \(name)")
            }
        })
    }

    func testUpdateProjectToolPersistsChanges() async throws {
        // Seed one project directly via a scan of a real fixture, exactly
        // like ServerTests does — an MCP write tool's effect should be
        // visible through the same REST read path afterward.
        let stlPath = mediaDir.appendingPathComponent("Figurine/piece.stl")
        try FileManager.default.createDirectory(at: stlPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: stlPath)
        await app.scanService.runScan()

        let project = try await ProjectModel.query(on: app.db).first()
        let projectId = try XCTUnwrap(project?.requireID()).uuidString

        let res = try await callTool("update_project", arguments: ["projectId": projectId, "notes": "Testé via MCP"])
        XCTAssertEqual(res.status, .ok)
        XCTAssertFalse(res.body.string.contains("\"isError\":true"))

        let reloaded = try await ProjectModel.find(UUID(uuidString: projectId), on: app.db)
        XCTAssertEqual(reloaded?.notes, "Testé via MCP")
    }
```

- [ ] **Step 2: Run the full MCP test suite**

Run: `swift test --filter MCPTests`
Expected: every test across Tasks 2–12 passes.

- [ ] **Step 3: Run the whole project test suite**

Run: `swift test`
Expected: every existing test (100 from before this plan) plus every `MCPTests` test passes — confirms the controller refactors didn't change any REST behavior.

- [ ] **Step 4: Document the endpoint in the README**

In `README.md`, insert a new subsection right after `### Authentification` and before `### Variables d'environnement` (grep for `### Variables d'environnement` to find the insertion point):

```markdown
### Serveur MCP (agents LLM)

`POST /api/mcp` expose la bibliothèque (projets, fichiers, scan, bibliothèques,
imprimantes, matériaux, réglages, Shopify, ForgeCore) à tout agent compatible
[MCP](https://modelcontextprotocol.io) — Claude Desktop, Claude Code, ou un
autre client — en lecture et écriture complètes.

Même mécanisme d'authentification que le reste de l'API : la clé API
(`Réglages → Clé API` dans le dashboard) doit être envoyée dans l'en-tête
`X-API-Key`. Dans la configuration MCP distante de Claude Desktop/Code,
renseigner l'URL `https://<votre-serveur>/api/mcp` et ajouter cet en-tête
personnalisé.

Pour vérifier manuellement la liste des tools disponibles et en appeler un
sans passer par un agent :

```bash
npx @modelcontextprotocol/inspector
# Transport: Streamable HTTP
# URL: https://<votre-serveur>/api/mcp
# Header personnalisé: X-API-Key: <votre clé>
```
```

- [ ] **Step 5: Manual smoke test (run once, by hand — not automated)**

1. Start a scratch server locally: `PRINTPLEX_MEDIA_PATH=/tmp/mcp-smoke/media PRINTPLEX_DATA_PATH=/tmp/mcp-smoke/data PRINTPLEX_ADMIN_USERNAME=admin PRINTPLEX_ADMIN_PASSWORD=admin1234 swift run PrintPlexServerApp serve --port 8799`
2. Fetch the API key: `curl -s -c /tmp/mcp-smoke/cookies.txt -X POST http://localhost:8799/api/auth/login -H "Content-Type: application/json" -d '{"username":"admin","password":"admin1234"}'` then `curl -s -b /tmp/mcp-smoke/cookies.txt http://localhost:8799/api/auth/api-key`
3. Run `npx @modelcontextprotocol/inspector`, connect with transport "Streamable HTTP", URL `http://localhost:8799/api/mcp`, custom header `X-API-Key: <key from step 2>`.
4. In the Inspector UI: confirm `tools/list` returns ~30 tools; call `list_projects` and confirm it returns `[]` on an empty library; call `create_library` with `{"name": "Test", "relativePath": ""}` and confirm it succeeds; call `trigger_scan`; call `list_projects` again.
5. Tear down: stop the server, `rm -rf /tmp/mcp-smoke`.

- [ ] **Step 6: Commit**

```bash
git add Tests/PrintPlexServerAppTests/MCPTests.swift README.md
git commit -m "test: cover full MCP request path end-to-end; docs: document /api/mcp"
```
