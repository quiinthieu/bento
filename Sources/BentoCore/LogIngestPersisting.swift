import Foundation

/// Pairs a discovered `LogSource` with a factory creating a fresh per-file `LogDecoder`.
public struct LogIngestTarget: Sendable {
    public var source: LogSource
    public var makeDecoder: @Sendable () -> any LogDecoder

    public init(
        source: LogSource,
        makeDecoder: @escaping @Sendable () -> any LogDecoder
    ) {
        self.source = source
        self.makeDecoder = makeDecoder
    }
}

/// Atomic batch of decoded events, session updates, and updated `log_file` cursor for a single log file.
public struct IngestedLogBatch: Sendable {
    public var fileState: LogFileState
    public var events: [StoredUsageEvent]
    public var sessions: [SessionRecord]

    public init(
        fileState: LogFileState,
        events: [StoredUsageEvent],
        sessions: [SessionRecord]
    ) {
        self.fileState = fileState
        self.events = events
        self.sessions = sessions
    }
}

/// Result counts returned by `LogIngestPersisting.recordIngestedLogBatch`.
public struct PersistedBatchCounts: Sendable, Equatable {
    public var eventsInserted: Int
    public var sessionsUpdated: Int

    public init(eventsInserted: Int, sessionsUpdated: Int) {
        self.eventsInserted = eventsInserted
        self.sessionsUpdated = sessionsUpdated
    }
}

/// Persistence interface linking `BentoLogIngest` to `BentoStore` without coupling module dependencies.
public protocol LogIngestPersisting: Sendable {
    /// Fetches the persisted cursor and file attributes for `path`, or `nil` if never ingested.
    func logFileState(forPath path: String) throws -> LogFileState?

    /// Resolves a `repo.id` matching `cwd` (either exact repo root or a nested subdirectory inside a known repo).
    func resolveRepoID(forCwd cwd: String?) throws -> String?

    /// Fetches previously persisted invocation ordinal counts per `sessionID` for an agent when resuming.
    func existingEventCountsBySession(agent: AgentID, sessionIDs: Set<String>) throws -> [String: Int]

    /// Atomically persists `usage_event` rows (deduping on `id`), upserts `session` rows, and updates `log_file`.
    @discardableResult
    func recordIngestedLogBatch(_ batch: IngestedLogBatch) throws -> PersistedBatchCounts

    /// Clears `log_file`, `usage_event`, and `session` rows for `bentoctx ingest --reset`.
    func resetLogIngestState() throws
}
