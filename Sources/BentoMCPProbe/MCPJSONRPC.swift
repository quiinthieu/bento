import BentoCore
import Foundation

/// Internal JSON-RPC 2.0 request/response codec for MCP `initialize` and `tools/list` (`PLAN.md` §6.4).
enum MCPJSONRPC {
    static let requestedProtocolVersion = "2025-03-26"
    static let maxPaginationPages = 100

    struct HandshakeResult: Sendable {
        var protocolVersion: String?
        var tools: [MCPToolSchema]
    }

    static func makeInitializeRequestData(id: Int) throws -> Data {
        let payload: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .int(Int64(id)),
            "method": .string("initialize"),
            "params": .object([
                "protocolVersion": .string(requestedProtocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string(Product.cliName),
                    "version": .string(Product.version)
                ])
            ])
        ]
        return try encodeLine(payload)
    }

    static func makeInitializedNotificationData() throws -> Data {
        let payload: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/initialized")
        ]
        return try encodeLine(payload)
    }

    static func makeToolsListRequestData(id: Int, cursor: String?) throws -> Data {
        var params: [String: JSONValue] = [:]
        if let cursor, !cursor.isEmpty {
            params["cursor"] = .string(cursor)
        }
        let payload: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .int(Int64(id)),
            "method": .string("tools/list"),
            "params": .object(params)
        ]
        return try encodeLine(payload)
    }

    static func matchesResponseID(_ object: [String: JSONValue], expectedID: Int) -> Bool {
        switch object["id"] {
        case .int(let value):
            return value == Int64(expectedID)
        case .double(let value):
            return Int(exactly: value) == expectedID
        case .string(let value):
            return Int(value) == expectedID
        default:
            return false
        }
    }

    static func parseInitializeResult(
        from response: [String: JSONValue],
        serverName: String,
        stderr: String
    ) throws -> String? {
        if let errorObj = response["error"] {
            throw BentoMCPProbeError.protocolError(
                serverName: serverName,
                reason: describeError(errorObj),
                stderr: stderr
            )
        }
        guard case .object(let result) = response["result"] else {
            throw BentoMCPProbeError.protocolError(
                serverName: serverName,
                reason: "Missing 'result' object in initialize response",
                stderr: stderr
            )
        }
        if case .string(let version) = result["protocolVersion"] {
            return version
        }
        return nil
    }

    static func parseToolsListResult(
        from response: [String: JSONValue],
        serverName: String,
        stderr: String
    ) throws -> (tools: [MCPToolSchema], nextCursor: String?) {
        if let errorObj = response["error"] {
            throw BentoMCPProbeError.protocolError(
                serverName: serverName,
                reason: describeError(errorObj),
                stderr: stderr
            )
        }
        guard case .object(let result) = response["result"] else {
            throw BentoMCPProbeError.protocolError(
                serverName: serverName,
                reason: "Missing 'result' object in tools/list response",
                stderr: stderr
            )
        }
        guard case .array(let rawTools) = result["tools"] else {
            throw BentoMCPProbeError.protocolError(
                serverName: serverName,
                reason: "Missing 'tools' array in tools/list result",
                stderr: stderr
            )
        }

        var tools: [MCPToolSchema] = []
        tools.reserveCapacity(rawTools.count)
        for item in rawTools {
            guard case .object(let dict) = item,
                case .string(let name) = dict["name"],
                !name.isEmpty
            else {
                continue
            }
            let description: String? =
                if case .string(let desc) = dict["description"] {
                    desc
                } else {
                    nil
                }
            let inputSchema = dict["inputSchema"] ?? dict["input_schema"]
            tools.append(
                MCPToolSchema(
                    name: name,
                    description: description,
                    inputSchema: inputSchema
                )
            )
        }

        let nextCursor: String?
        if case .string(let cursor) = result["nextCursor"], !cursor.isEmpty {
            nextCursor = cursor
        } else if case .string(let cursor) = result["next_cursor"], !cursor.isEmpty {
            nextCursor = cursor
        } else {
            nextCursor = nil
        }

        return (tools, nextCursor)
    }

    static func decodeJSONObject(_ data: Data) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private static func encodeLine(_ object: [String: JSONValue]) throws -> Data {
        var data = try JSONEncoder().encode(object)
        data.append(0x0A)
        return data
    }

    private static func describeError(_ errorValue: JSONValue) -> String {
        if case .object(let dict) = errorValue {
            let code: String =
                if case .int(let c) = dict["code"] {
                    "code \(c)"
                } else {
                    "error"
                }
            if case .string(let msg) = dict["message"] {
                return "\(code): \(msg)"
            }
            return code
        }
        return String(describing: errorValue)
    }
}
