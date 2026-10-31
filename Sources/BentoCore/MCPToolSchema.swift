import Foundation

/// Schema summary of an MCP tool returned by `tools/list` (`PLAN.md` §6.4, §11 T10).
public struct MCPToolSchema: Sendable, Codable, Hashable {
    /// Tool identifier exposed by the MCP server.
    public var name: String
    /// Optional human/model-facing tool description.
    public var description: String?
    /// Optional JSON Schema object describing the tool's input arguments.
    public var inputSchema: JSONValue?

    /// Creates an MCP tool schema summary.
    public init(
        name: String,
        description: String? = nil,
        inputSchema: JSONValue? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    private struct SerializationEnvelope: Encodable {
        var name: String
        var description: String
        var inputSchema: JSONValue
    }

    /// Produces a deterministic JSON representation of `{name, description, inputSchema}`
    /// used to estimate per-tool prompt token cost (`PLAN.md` §6.4).
    public func canonicalSerializationJSON() -> String {
        let envelope = SerializationEnvelope(
            name: name,
            description: description ?? "",
            inputSchema: inputSchema ?? .object(["type": .string("object")])
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(envelope) else {
            return "{\"name\":\(String(reflecting: name))}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
