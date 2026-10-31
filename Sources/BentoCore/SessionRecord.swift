import Foundation

/// Aggregated session metadata persisted in the `session` SQLite table (`PLAN.md` §4.2).
public struct SessionRecord: Sendable, Codable, Hashable {
    /// Agent that produced the session.
    public var agent: AgentID
    /// Agent-assigned session identifier.
    public var sessionID: String
    /// Earliest timestamp observed for this session.
    public var startedAt: Date
    /// Working directory associated with the session, if known.
    public var cwd: String?
    /// Matched `repo.id` in `BentoStore` when `cwd` falls inside a discovered repository.
    public var repoID: String?
    /// Model identifier observed in the session, if known.
    public var model: String?
    /// Total input tokens recorded on the session's first assistant turn (`turnIndex == 0`).
    public var firstTurnInput: Int?
    /// Privacy-safe character length (never text!) of the session's first user message, if logged (`PLAN.md` §6.3).
    public var firstUserMessageCharCount: Int?

    /// Creates a session record.
    public init(
        agent: AgentID,
        sessionID: String,
        startedAt: Date,
        cwd: String? = nil,
        repoID: String? = nil,
        model: String? = nil,
        firstTurnInput: Int? = nil,
        firstUserMessageCharCount: Int? = nil
    ) {
        self.agent = agent
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.cwd = cwd
        self.repoID = repoID
        self.model = model
        self.firstTurnInput = firstTurnInput
        self.firstUserMessageCharCount = firstUserMessageCharCount
    }
}

/// Persisted `UsageEvent` enriched with deterministic deduplication `id`, matched `repoID`, and active `model`.
public struct StoredUsageEvent: Sendable, Codable, Hashable, Identifiable {
    /// Deterministic SHA-256 hex identifier `(agent, session_id, event_uid)` used for rotation deduplication.
    public var id: String
    /// Decoded privacy-safe usage event.
    public var event: UsageEvent
    /// Matched `repo.id` in `BentoStore`, if `event.cwd` belongs to a known repository.
    public var repoID: String?
    /// Active model identifier associated with this event or session, if known.
    public var model: String?

    /// Creates a stored usage event wrapper.
    public init(
        id: String,
        event: UsageEvent,
        repoID: String? = nil,
        model: String? = nil
    ) {
        self.id = id
        self.event = event
        self.repoID = repoID
        self.model = model
    }
}
