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
