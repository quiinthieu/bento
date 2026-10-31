/// Persistence abstraction for `mcp_probe` records and median fallback statistics (`PLAN.md` §3.2, §4.2, §6.4).
public protocol MCPProbeCaching: Sendable {
    /// Looks up a previously saved probe record by `serverConfigHash`.
    func cachedMCPProbe(forHash serverConfigHash: String) throws -> MCPProbeRecord?

    /// Inserts or replaces an `MCPProbeRecord` keyed by `record.serverConfigHash`.
    func saveMCPProbe(_ record: MCPProbeRecord) throws

    /// Fetches all persisted `MCPProbeRecord` rows ordered by `probedAt` descending.
    func allMCPProbes() throws -> [MCPProbeRecord]

    /// Computes median per-tool and per-server fallback statistics across successful probes, or `nil` if none exist.
    func mcpFallbackEstimate() throws -> MCPFallbackEstimate?
}

/// Persistence abstraction for storing approved MCP `serverConfigHash` values (`PLAN.md` §6.4, §7).
public protocol MCPConsentPersisting: Sendable {
    /// Loads the set of explicitly approved `serverConfigHash` digests.
    func consentedMCPConfigHashes() throws -> Set<String>

    /// Persists the set of explicitly approved `serverConfigHash` digests.
    func saveConsentedMCPConfigHashes(_ hashes: Set<String>) throws
}
