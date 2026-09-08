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
                required: upsertProperties.keys.sorted())),
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
