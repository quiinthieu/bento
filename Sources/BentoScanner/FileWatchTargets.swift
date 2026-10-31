/// Directories monitored by a `FileWatcher`, partitioned into high-priority configuration roots
/// and lower-priority session log roots (`PLAN.md` §6.1).
public struct FileWatchTargets: Sendable, Codable, Hashable {
    /// Agent home configuration directories and pinned-repository agent subpaths.
    public var configurationPaths: [String]
    /// Agent session log directories monitored on a separate lower-priority stream.
    public var logPaths: [String]

    /// Creates a file-watcher target set.
    public init(configurationPaths: [String] = [], logPaths: [String] = []) {
        self.configurationPaths = Array(Set(configurationPaths)).sorted()
        self.logPaths = Array(Set(logPaths)).sorted()
    }
}
