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
