/// Read-only filesystem change watcher abstraction (`PLAN.md` §6.1).
public protocol FileWatcher: Sendable {
    /// Starts watching `targets` and returns an asynchronous stream of debounced `FileChangeEvent` batches.
    func start(watching targets: FileWatchTargets) async -> AsyncStream<FileChangeEvent>

    /// Replaces the watched directory set while keeping the active consumer stream alive.
    func update(targets: FileWatchTargets) async

    /// Stops all underlying streams or polling tasks and finishes the event sequence.
    func stop() async
}
