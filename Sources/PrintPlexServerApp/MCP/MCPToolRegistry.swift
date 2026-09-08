import Vapor
import MCP

/// Each controller-group's `*MCPTools.swift` file appends its own
/// `.tools`/`.call` to these two arrays — see Task 3 onward.
enum MCPToolRegistry {
    static let toolGroups: [[Tool]] = [
        ProjectMCPTools.tools,
        FileMCPTools.tools,
        ScanMCPTools.tools,
        LibraryMCPTools.tools,
        PrinterMCPTools.tools,
        MaterialMCPTools.tools,
        SettingsMCPTools.tools,
        ShopifyMCPTools.tools,
        ForgeCoreMCPTools.tools,
    ]
    static let callHandlers: [@Sendable (String, [String: Value]?, Application) async throws -> CallTool.Result?] = [
        ProjectMCPTools.call,
        FileMCPTools.call,
        ScanMCPTools.call,
        LibraryMCPTools.call,
        PrinterMCPTools.call,
        MaterialMCPTools.call,
        SettingsMCPTools.call,
        ShopifyMCPTools.call,
        ForgeCoreMCPTools.call,
    ]

    static var allTools: [Tool] { toolGroups.flatMap { $0 } }

    static func call(name: String, arguments: [String: Value]?, app: Application) async throws -> CallTool.Result {
        for handler in callHandlers {
            if let result = try await handler(name, arguments, app) {
                return result
            }
        }
        return toolErrorResult("Tool inconnu : \(name)")
    }
}
