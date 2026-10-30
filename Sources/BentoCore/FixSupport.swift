/// Declares which reversible fixes an `AgentAdapter` supports and agent-specific syntax conventions.
public struct FixSupport: Sendable, Codable, Hashable {
    /// Fix kinds supported for this agent.
    public var supportedKinds: Set<FixKind>
    /// Whether rule files for this agent support `@path` import directives (e.g. `@AGENTS.md`).
    public var supportsAtImports: Bool

    /// Creates a fix support descriptor.
    public init(supportedKinds: Set<FixKind> = [], supportsAtImports: Bool = false) {
        self.supportedKinds = supportedKinds
        self.supportsAtImports = supportsAtImports
    }
}
