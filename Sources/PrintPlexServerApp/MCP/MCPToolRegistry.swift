import Vapor
import MCP

/// Each controller-group's `*MCPTools.swift` file appends its own
/// `.tools`/`.call` to these two arrays — see Task 3 onward.
enum MCPToolRegistry {
    static let toolGroups: [[Tool]] = []
    static let callHandlers: [@Sendable (String, [String: Value]?, Application) async throws -> CallTool.Result?] = []

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
