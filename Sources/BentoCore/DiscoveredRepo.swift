import Foundation

/// Deduplicated repository/workspace folder discovered from agent logs, configs, or user roots (PLAN §5.3).
public struct DiscoveredRepo: Sendable, Codable, Hashable {
    /// Preferred absolute path (non-symlink path preferred when available).
    public var path: String
    /// Canonical real path with all symbolic links resolved (deduplication key).
    public var realPath: String
    /// Human-readable folder name (`lastPathComponent` of `path`).
    public var displayName: String
    /// Sorted list of discovery sources that referenced this repository.
    public var sources: [RepoDiscoverySource]
    /// Whether the repository is explicitly pinned by the user.
    public var isPinned: Bool

    /// Creates a discovered repository descriptor.
    public init(
        path: String,
        realPath: String,
        displayName: String,
        sources: [RepoDiscoverySource],
        isPinned: Bool = false
    ) {
        self.path = path
        self.realPath = realPath
        self.displayName = displayName
        self.sources = Array(Set(sources)).sorted()
        self.isPinned = isPinned
    }
}
