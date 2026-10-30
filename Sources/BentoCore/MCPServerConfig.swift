/// Configuration summary for a discovered MCP server entry.
/// Environment variable values and secret headers are never stored.
public struct MCPServerConfig: Sendable, Codable, Hashable {
    /// Transport mechanism used to communicate with the MCP server.
    public enum Transport: Sendable, Codable, Hashable {
        case stdio(command: String, args: [String])
        case http(url: String)
        case sse(url: String)
    }

    /// Configured transport endpoint or command.
    public var transport: Transport
    /// Declared environment variable names only (values are never persisted).
    public var envKeys: [String]
    /// Whether the server entry is marked disabled in configuration.
    public var disabled: Bool
    /// Optional allow-list of tool names exposed from this server.
    public var allowedTools: [String]?
    /// Optional deny-list of tool names excluded from this server.
    public var disabledTools: [String]?

    /// Creates an MCP server configuration payload.
    public init(
        transport: Transport,
        envKeys: [String] = [],
        disabled: Bool = false,
        allowedTools: [String]? = nil,
        disabledTools: [String]? = nil
    ) {
        self.transport = transport
        self.envKeys = envKeys
        self.disabled = disabled
        self.allowedTools = allowedTools
        self.disabledTools = disabledTools
    }
}
