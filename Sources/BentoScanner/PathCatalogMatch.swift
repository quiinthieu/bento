import BentoCore

/// Result of matching changed filesystem paths against all registered `PathCatalog` definitions.
public struct PathCatalogMatch: Sendable, Hashable {
    /// Configuration and artifact `(agent, repoPath)` scopes affected by the changed paths.
    public var scopes: Set<ScanScope>
    /// Agents whose session log patterns matched at least one changed path.
    public var logAgents: Set<AgentID>

    /// Creates a `PathCatalog` match result.
    public init(scopes: Set<ScanScope> = [], logAgents: Set<AgentID> = []) {
        self.scopes = scopes
        self.logAgents = logAgents
    }

    /// `true` when neither configuration scopes nor log patterns matched.
    public var isEmpty: Bool {
        scopes.isEmpty && logAgents.isEmpty
    }
}
