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
