import Vapor
import PrintPlexCore
import MCP

/// A `configured`/`storeDomain`-only view of Shopify settings for MCP —
/// unlike the dashboard's own settings screen (which needs the plaintext
/// token to prefill an edit form for a human), an agent never needs to read
/// the raw secret back.
struct ShopifySettingsSummary: Codable {
    var storeDomain: String
    var configured: Bool
}

enum SettingsMCPTools {
    static let tools: [Tool] = [
        Tool(name: "get_settings",
             description: "Réglages généraux du serveur (chemins média/données, cadence de scan, état Shopify).",
             inputSchema: objectSchema()),
        Tool(name: "update_scan_settings",
             description: "Met à jour la cadence de scan automatique.",
             inputSchema: objectSchema(properties: [
                "autoScanEnabled": boolProp("Activer le scan automatique périodique"),
                "scanIntervalMinutes": intProp("Intervalle entre deux scans automatiques, en minutes"),
             ])),
        Tool(name: "get_shopify_settings",
             description: "Domaine de la boutique Shopify configurée et si elle est prête à l'emploi (le jeton d'accès n'est jamais renvoyé).",
             inputSchema: objectSchema()),
        Tool(name: "update_shopify_settings",
             description: "Configure les identifiants Shopify (domaine de boutique et jeton d'accès).",
             inputSchema: objectSchema(
                properties: [
                    "storeDomain": stringProp("Domaine de la boutique Shopify (ex: maboutique.myshopify.com)"),
                    "accessToken": stringProp("Jeton d'accès API Shopify"),
                ],
                required: ["storeDomain", "accessToken"])),
    ]

    static func call(_ name: String, _ arguments: [String: Value]?, app: Application) async throws -> CallTool.Result? {
        switch name {
        case "get_settings":
            return try await toolResult(SettingsController.fetchOverview(app: app))

        case "update_scan_settings":
            let body = try decodeArguments(ScanSettingsUpdateRequest.self, from: arguments)
            return try await toolResult(app.scanService.updateScanSettings(
                autoScanEnabled: body.autoScanEnabled, scanIntervalMinutes: body.scanIntervalMinutes))

        case "get_shopify_settings":
            let settings = try await SettingsController.fetchShopifySettings(on: app.db)
            return try toolResult(ShopifySettingsSummary(storeDomain: settings.storeDomain, configured: settings.configured))

        case "update_shopify_settings":
            let body = try decodeArguments(ShopifySettingsUpdateRequest.self, from: arguments)
            return try await toolResult(SettingsController.applyShopifyUpdate(body, app: app))

        default:
            return nil
        }
    }
}
