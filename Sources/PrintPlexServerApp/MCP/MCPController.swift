import Vapor
import MCP

struct MCPController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let mcp = routes.grouped("api", "mcp")
        mcp.on(.POST, body: .collect(maxSize: "10mb"), use: handle)
    }

    @Sendable
    func handle(req: Vapor.Request) async throws -> Vapor.Response {
        let transport = try await makeMCPTransport(app: req.application)
        let mcpRequest = mcpHTTPRequest(from: req)
        let mcpResponse = await transport.handleRequest(mcpRequest)
        return vaporResponse(from: mcpResponse)
    }
}

/// Builds a fresh MCP `Server` + `StatelessHTTPServerTransport` pair for a
/// single HTTP request, and wires it to the two method handlers every tool
/// group dispatches through.
///
/// The SDK's `Server` actor tracks `isInitialized` as a single flag for its
/// whole lifetime. Sharing one `Server` across every incoming request meant
/// only the very first client's `initialize` call ever succeeded — every
/// other client (or a reconnect) was rejected with "Server is already
/// initialized". A fresh, in-process `Server` per request avoids that
/// entirely, and costs nothing structurally: this is exactly the "stateless,
/// single JSON request/response" contract `StatelessHTTPServerTransport` was
/// chosen for, and `configuration: .default` (non-strict) means
/// `tools/list`/`tools/call` never require a prior `initialize` on the same
/// instance anyway.
func makeMCPTransport(app: Application) async throws -> StatelessHTTPServerTransport {
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
    return transport
}
