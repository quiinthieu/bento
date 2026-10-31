/// Identifies an incremental discovery and resolution unit: a single `AgentID` paired with either
/// global/user scope (`repoPath == nil`) or a specific repository folder (`repoPath != nil`).
public struct ScanScope: Sendable, Codable, Hashable, Comparable {
    /// Target coding agent identifier.
    public var agent: AgentID
    /// Standardized repository path, or `nil` for global-only discovery.
    public var repoPath: String?

    /// Creates a scan scope descriptor.
    public init(agent: AgentID, repoPath: String? = nil) {
        self.agent = agent
        self.repoPath = repoPath
    }

    public static func < (lhs: ScanScope, rhs: ScanScope) -> Bool {
        if lhs.agent != rhs.agent {
            return lhs.agent < rhs.agent
        }
        switch (lhs.repoPath, rhs.repoPath) {
        case (nil, nil):
            return false
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        case (.some(let leftPath), .some(let rightPath)):
            return leftPath < rightPath
        }
    }
}
