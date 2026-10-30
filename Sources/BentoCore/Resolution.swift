/// Ordered, precedence-merged set of artifacts an agent loads when launched in a target folder.
public struct Resolution: Sendable, Codable, Hashable {
    /// Agent for which resolution was computed.
    public var agent: AgentID
    /// Absolute path of the target working folder.
    public var folder: String
    /// Active artifacts in effective load order.
    public var ordered: [ResolvedArtifact]
    /// Artifacts shadowed by higher-precedence entries.
    public var shadowed: [ShadowRecord]
    /// Resolution-level warnings (e.g. unapproved `.mcp.json` servers).
    public var warnings: [Diagnostic]

    /// Creates a resolution result.
    public init(
        agent: AgentID,
        folder: String,
        ordered: [ResolvedArtifact],
        shadowed: [ShadowRecord] = [],
        warnings: [Diagnostic] = []
    ) {
        self.agent = agent
        self.folder = folder
        self.ordered = ordered
        self.shadowed = shadowed
        self.warnings = warnings
    }
}
