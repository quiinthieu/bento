/// Normalized representation of a single configuration file or structured entry discovered for an agent.
public struct Artifact: Sendable, Codable, Identifiable, Hashable {
    /// Deterministic SHA-256 identity derived from `(agent, kind, scope, path, keyPath)`.
    public var id: ArtifactID
    /// Owning coding agent.
    public var agent: AgentID
    /// Artifact category.
    public var kind: ArtifactKind
    /// Precedence scope tier.
    public var scope: Scope
    /// Display name (skill name, MCP server key, or file name).
    public var name: String
    /// Source file coordinates and optional structured key path / line span.
    public var location: SourceLocation
    /// Lowercase SHA-256 hex digest of normalized content bytes.
    public var contentHash: String
    /// Effective enabled state after applying disable flags.
    public var enabled: Bool
    /// Context entry mode prior to precedence resolution overrides.
    public var loadMode: LoadMode
    /// Kind-specific parsed payload.
    public var payload: ArtifactPayload
    /// Parse or validation diagnostics attached to this artifact.
    public var diagnostics: [Diagnostic]

    /// Creates an artifact record.
    public init(
        id: ArtifactID,
        agent: AgentID,
        kind: ArtifactKind,
        scope: Scope,
        name: String,
        location: SourceLocation,
        contentHash: String,
        enabled: Bool,
        loadMode: LoadMode,
        payload: ArtifactPayload,
        diagnostics: [Diagnostic] = []
    ) {
        self.id = id
        self.agent = agent
        self.kind = kind
        self.scope = scope
        self.name = name
        self.location = location
        self.contentHash = contentHash
        self.enabled = enabled
        self.loadMode = loadMode
        self.payload = payload
        self.diagnostics = diagnostics
    }
}
