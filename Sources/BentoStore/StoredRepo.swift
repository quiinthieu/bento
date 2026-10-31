import Foundation

/// Persisted repository row stored in the `repo` SQLite table (`PLAN.md` §4.2).
public struct StoredRepo: Sendable, Codable, Hashable, Identifiable {
    /// Deterministic SHA-256 repository identifier.
    public var id: String
    /// Preferred standardized repository path (`UNIQUE` in SQLite).
    public var path: String
    /// Canonical symlink-resolved repository path.
    public var realPath: String
    /// Human-readable repository folder name.
    public var displayName: String
    /// Timestamp when the repository was most recently observed.
    public var lastSeenAt: Date
    /// Whether the user explicitly pinned this repository.
    public var isPinned: Bool

    /// Creates a persisted repository record.
    public init(
        id: String,
        path: String,
        realPath: String,
        displayName: String,
        lastSeenAt: Date,
        isPinned: Bool
    ) {
        self.id = id
        self.path = path
        self.realPath = realPath
        self.displayName = displayName
        self.lastSeenAt = lastSeenAt
        self.isPinned = isPinned
    }
}
