import Foundation

/// Persisted result of probing a consented MCP server (`mcp_probe` table, `PLAN.md` §4.2, §6.4).
public struct MCPProbeRecord: Sendable, Codable, Hashable {
    /// Deterministic SHA-256 config hash (`MCPServerConfigHasher.hash`).
    public var serverConfigHash: String
    /// Agent that initiated the probe.
    public var agent: AgentID
    /// Configured logical server name.
    public var serverName: String
    /// Timestamp when the probe completed.
    public var probedAt: Date
    /// Whether the probe handshake and `tools/list` succeeded.
    public var ok: Bool
    /// Error summary when `ok == false`, or `nil` on success.
    public var error: String?
    /// Discovered tool schemas across all paginated `tools/list` pages.
    public var tools: [MCPToolSchema]
    /// Estimated token cost across all `tools` at probe time.
    public var toolsTokensEstimate: Int
    /// Negotiated MCP protocol version returned by `initialize`, if present.
    public var protocolVersion: String?

    /// Creates an MCP probe record.
    public init(
        serverConfigHash: String,
        agent: AgentID,
        serverName: String,
        probedAt: Date,
        ok: Bool,
        error: String? = nil,
        tools: [MCPToolSchema] = [],
        toolsTokensEstimate: Int = 0,
        protocolVersion: String? = nil
    ) {
        self.serverConfigHash = serverConfigHash
        self.agent = agent
        self.serverName = serverName
        self.probedAt = probedAt
        self.ok = ok
        self.error = error
        self.tools = tools
        self.toolsTokensEstimate = toolsTokensEstimate
        self.protocolVersion = protocolVersion
    }

    /// Filters `tools` according to `config.allowedTools` (allow-list) and `config.disabledTools` (deny-list).
    public func activeTools(for config: MCPServerConfig) -> [MCPToolSchema] {
        let allowSet = config.allowedTools.map(Set.init)
        let denySet = Set(config.disabledTools ?? [])
        return tools.filter { tool in
            if let allowSet, !allowSet.contains(tool.name) {
                return false
            }
            if denySet.contains(tool.name) {
                return false
            }
            return true
        }
    }
}

/// Historical median fallback token statistics computed from previously probed MCP servers (`PLAN.md` §6.4).
public struct MCPFallbackEstimate: Sendable, Codable, Hashable {
    /// Median estimated tokens per tool across previously probed servers.
    public var medianTokensPerTool: Int
    /// Median number of tools exposed per previously probed server.
    public var medianToolsPerServer: Int
    /// Number of successful server probes contributing to this median.
    public var sampleServerCount: Int

    /// Creates a historical MCP fallback estimate.
    public init(
        medianTokensPerTool: Int,
        medianToolsPerServer: Int,
        sampleServerCount: Int
    ) {
        self.medianTokensPerTool = max(1, medianTokensPerTool)
        self.medianToolsPerServer = max(1, medianToolsPerServer)
        self.sampleServerCount = max(0, sampleServerCount)
    }

    /// Computes a fallback token estimate for an unprobed `config`, scaling by `allowedTools.count` when specified.
    public func estimatedServerTokens(for config: MCPServerConfig) -> Int {
        if let allowed = config.allowedTools, !allowed.isEmpty {
            let denySet = Set(config.disabledTools ?? [])
            let activeAllowedCount = allowed.filter { !denySet.contains($0) }.count
            return max(0, activeAllowedCount) * medianTokensPerTool
        }
        return medianToolsPerServer * medianTokensPerTool
    }
}
