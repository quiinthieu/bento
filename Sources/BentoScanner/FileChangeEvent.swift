import Foundation

/// Batch of debounced filesystem change paths emitted by a `FileWatcher` (`PLAN.md` §6.1).
public struct FileChangeEvent: Sendable, Codable, Hashable {
    /// Watcher stream priority classification.
    public enum StreamKind: String, Sendable, Codable, Hashable {
        case configuration
        case logs
    }

    /// Standardized filesystem paths reported as created, modified, renamed, or deleted.
    public var paths: [String]
    /// Originating stream classification (`.configuration` vs `.logs`).
    public var streamKind: StreamKind
    /// Indicates that kernel or watcher event coalescing requires a full rescan.
    public var requiresFullRescan: Bool
    /// Timestamp when the batch was emitted.
    public var timestamp: Date

    /// Creates a filesystem change event batch.
    public init(
        paths: [String],
        streamKind: StreamKind = .configuration,
        requiresFullRescan: Bool = false,
        timestamp: Date = Date()
    ) {
        self.paths = paths
        self.streamKind = streamKind
        self.requiresFullRescan = requiresFullRescan
        self.timestamp = timestamp
    }
}
