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
