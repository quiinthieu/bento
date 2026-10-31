import Foundation

/// Deterministic manual `FileWatcher` test double for driving incremental rescans (`PLAN.md` §6.1).
public actor ManualFileWatcher: FileWatcher {
    private var targets = FileWatchTargets()
    private var continuation: AsyncStream<FileChangeEvent>.Continuation?

    /// Creates a manual file watcher.
    public init() {}

    /// Currently registered watch targets.
    public var currentTargets: FileWatchTargets {
        targets
    }

    public func start(watching targets: FileWatchTargets) async -> AsyncStream<FileChangeEvent> {
        self.targets = targets
        continuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: FileChangeEvent.self)
        self.continuation = continuation
        return stream
    }

    public func update(targets: FileWatchTargets) async {
        self.targets = targets
    }

    public func stop() async {
        continuation?.finish()
        continuation = nil
    }

    /// Emits `event` synchronously into the active watcher stream.
    public func emit(_ event: FileChangeEvent) {
        continuation?.yield(event)
    }

    /// Convenience helper emitting a `FileChangeEvent` for `paths`.
    public func emit(
        paths: [String],
        streamKind: FileChangeEvent.StreamKind = .configuration,
        requiresFullRescan: Bool = false,
        timestamp: Date = Date()
    ) {
        emit(
            FileChangeEvent(
                paths: paths,
                streamKind: streamKind,
                requiresFullRescan: requiresFullRescan,
                timestamp: timestamp
            )
        )
    }
}
