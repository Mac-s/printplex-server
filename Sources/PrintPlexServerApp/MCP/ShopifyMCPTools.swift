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
        Tool(name: "update_shopify_product",
             description: "Met à jour les champs texte d'un produit Shopify existant (titre, description, marque, type, tags, méta titre/description SEO). Seuls les champs fournis sont modifiés.",
             inputSchema: objectSchema(
                properties: [
                    "productId": stringProp("ID numérique du produit Shopify"),
                    "title": stringProp("Nouveau titre"),
                    "bodyHtml": stringProp("Nouvelle description HTML"),
                    "vendor": stringProp("Marque/fournisseur"),
                    "productType": stringProp("Type de produit"),
                    "tags": stringProp("Tags, séparés par des virgules"),
                    "metaTitle": stringProp("Méta titre SEO (balise title)"),
                    "metaDescription": stringProp("Méta description SEO"),
                ],
                required: ["productId"])),
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

        case "update_shopify_product":
            guard let raw = arguments?["productId"]?.stringValue, let id = Int(raw) else {
                throw MCPToolError.invalidArguments("productId manquant ou invalide")
            }
            let body = try decodeArguments(ShopifyUpdateProductRequest.self, from: arguments)
            return try await toolResult(ShopifyController.updateProduct(id: id, body, app: app))

        case "sync_shopify":
            return try await toolResult(ShopifyController.syncShopify(app: app))

        default:
            return nil
        }
    }
}
