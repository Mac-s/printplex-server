import Vapor
import Foundation
import MCP

// MARK: - Vapor <-> MCP HTTP bridge

func mcpHTTPRequest(from req: Vapor.Request) -> MCP.HTTPRequest {
    var headers: [String: String] = [:]
    for (name, value) in req.headers {
        headers[name] = value
    }
    let bodyData = req.body.data.map { Data(buffer: $0) }
    return MCP.HTTPRequest(
        method: req.method.rawValue,
        headers: headers,
        body: bodyData,
        path: req.url.path
    )
}

func vaporResponse(from mcpResponse: MCP.HTTPResponse) -> Vapor.Response {
    switch mcpResponse {
    case .accepted(let headers):
        return rawResponse(status: .accepted, headers: headers, body: nil)
    case .ok(let headers):
        return rawResponse(status: .ok, headers: headers, body: nil)
    case .data(let data, let headers):
        return rawResponse(status: .ok, headers: headers, body: data)
    case .error(let statusCode, _, _, _):
        return rawResponse(status: HTTPStatus(statusCode: statusCode), headers: mcpResponse.headers, body: mcpResponse.bodyData)
    case .stream:
        // StatelessHTTPServerTransport never returns this for POST (its own
        // doc comment: "POST requests receive direct JSON responses (no SSE
        // streaming)") — kept exhaustive in case a future SDK version adds
        // stream support we haven't opted into.
        return rawResponse(status: .notImplemented, headers: [:], body: nil)
    }
}

private func rawResponse(status: HTTPStatus, headers: [String: String], body: Data?) -> Vapor.Response {
    var vaporHeaders = HTTPHeaders()
    for (name, value) in headers {
        vaporHeaders.replaceOrAdd(name: name, value: value)
    }
    let response = Vapor.Response(status: status, headers: vaporHeaders)
    if let body {
        response.body = .init(data: body)
    }
    return response
}

// MARK: - Value <-> Codable bridging

enum MCPToolError: Error {
    case invalidArguments(String)
}

/// Decodes a tool call's `arguments` dictionary into an existing `Content`
/// (or any `Decodable`) request type — the same type the matching REST route
/// already decodes from its JSON body, so argument parsing stays identical
/// between the two entry points.
func decodeArguments<T: Decodable>(_ type: T.Type, from arguments: [String: Value]?) throws -> T {
    let value = Value.object(arguments ?? [:])
    let data = try JSONEncoder().encode(value)
    do {
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        throw MCPToolError.invalidArguments("\(error)")
    }
}

func toolResult<T: Codable>(_ value: T) throws -> CallTool.Result {
    let data = try JSONEncoder().encode(value)
    let text = String(decoding: data, as: UTF8.self)
    return try CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: value)
}

func toolSuccess(_ message: String) -> CallTool.Result {
    CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)])
}

func toolErrorResult(_ message: String) -> CallTool.Result {
    CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
}

// MARK: - JSON Schema builders for Tool.inputSchema

func objectSchema(properties: [String: Value] = [:], required: [String] = []) -> Value {
    .object([
        "type": .string("object"),
        "properties": .object(properties),
        "required": .array(required.map(Value.string)),
    ])
}

func stringProp(_ description: String) -> Value {
    .object(["type": .string("string"), "description": .string(description)])
}

func intProp(_ description: String) -> Value {
    .object(["type": .string("integer"), "description": .string(description)])
}

func numberProp(_ description: String) -> Value {
    .object(["type": .string("number"), "description": .string(description)])
}

func boolProp(_ description: String) -> Value {
    .object(["type": .string("boolean"), "description": .string(description)])
}

func arrayProp(_ description: String, items: Value = .object(["type": .string("string")])) -> Value {
    .object(["type": .string("array"), "description": .string(description), "items": items])
}
