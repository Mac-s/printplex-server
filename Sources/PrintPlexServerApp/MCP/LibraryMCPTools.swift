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
