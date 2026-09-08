import Vapor
import MCP

struct MCPController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let mcp = routes.grouped("api", "mcp")
        mcp.on(.POST, body: .collect(maxSize: "10mb"), use: handle)
    }

    @Sendable
    func handle(req: Vapor.Request) async throws -> Vapor.Response {
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
