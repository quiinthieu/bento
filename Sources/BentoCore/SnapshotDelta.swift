/// Notification emitted by `Workspace` after a full or incremental scan updates the live `Snapshot`.
public struct SnapshotDelta: Sendable, Codable, Hashable {
    /// Kind of scan that produced `snapshot`.
    public enum Reason: String, Sendable, Codable, Hashable {
        case fullScan
        case incrementalRescan
    }

    /// Updated immutable workspace snapshot.
    public var snapshot: Snapshot
    /// Scan trigger classification.
    public var reason: Reason
    /// Sorted list of `(agent, repoPath)` scopes re-discovered during this update.
    public var rescannedScopes: [ScanScope]
    /// Filesystem paths that triggered an incremental update (empty for explicit full scans).
    public var changedPaths: [String]
    /// Agents whose log directories reported file changes in this batch.
    public var changedLogAgents: [AgentID]

    /// Creates a snapshot delta record.
    public init(
        snapshot: Snapshot,
        reason: Reason,
        rescannedScopes: [ScanScope],
        changedPaths: [String] = [],
        changedLogAgents: [AgentID] = []
    ) {
        self.snapshot = snapshot
        self.reason = reason
        self.rescannedScopes = rescannedScopes.sorted()
        self.changedPaths = changedPaths.sorted()
        self.changedLogAgents = Array(Set(changedLogAgents)).sorted()
    }
}
