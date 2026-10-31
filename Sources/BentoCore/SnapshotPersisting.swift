/// Persistence seam allowing `BentoScanner` (`Workspace`) to persist and restore `Snapshot` values
/// without importing `BentoStore` directly (preserving `PLAN.md` §3.2 module boundaries).
public protocol SnapshotPersisting: Sendable {
    /// Persists `snapshot` and its associated artifact and repository rows atomically.
    func saveSnapshot(_ snapshot: Snapshot) throws

    /// Loads the most recently saved `Snapshot`, optionally constrained to `homeHash`.
    func loadLatestSnapshot(homeHash: String?) throws -> Snapshot?

    /// Returns the set of repository paths currently marked as pinned in persistent storage.
    func pinnedRepoPaths() throws -> Set<String>
}
