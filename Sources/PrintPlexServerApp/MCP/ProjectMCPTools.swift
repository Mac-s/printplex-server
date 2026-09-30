import Vapor
import PrintPlexCore
import MCP

enum ProjectMCPTools {
    static let tools: [Tool] = [
        Tool(
            name: "list_projects",
            description: "Liste les projets de la bibliothèque (vue compacte : id, nom, catégorie, créateur, tags, personnages, nombre de fichiers), triés par date de modification décroissante, avec filtres et pagination. Sans argument, renvoie au plus 50 projets. Utiliser get_project pour le détail complet d'un projet.",
            inputSchema: objectSchema(
                properties: [
                    "category": stringProp("Filtrer par catégorie exacte"),
                    "creator": stringProp("Filtrer par créateur exact"),
                    "tag": stringProp("Filtrer par tag exact"),
                    "character": stringProp("Filtrer par personnage exact"),
                    "search": stringProp("Recherche texte (nom, catégorie, créateur, tags)"),
                    "limit": intProp("Nombre de résultats (défaut 50, max 200)"),
                    "offset": intProp("Décalage pour la pagination (défaut 0)"),
                ]
            )
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
                    "characters": arrayProp("Liste complète des personnages (remplace l'existante)"),
                    "suggestedMaterials": arrayProp("Liste complète des matériaux suggérés"),
                    "multiColor": boolProp("Multi-couleur"),
                    "notes": stringProp("Notes libres"),
                    "alreadyPrinted": boolProp("Déjà imprimé"),
                    "sourceUrl": stringProp("URL source (chaîne vide pour effacer)"),
                    "shopifyProductId": stringProp("ID du produit Shopify lié (chaîne vide pour délier)"),
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
            let query = try decodeArguments(ProjectListQuery.self, from: arguments)
            return try await toolResult(ProjectController.fetchIndexPage(query: query, on: app.db))

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
