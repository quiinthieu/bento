import Foundation

/// Lifecycle state of a `fix_journal` entry (`PLAN.md` §4.2, §6.6).
public enum FixJournalStatus: String, Sendable, Codable, CaseIterable {
    case pending
    case applied
    case undone
    case rolledBack = "rolled_back"
    case failed
}

/// Persisted audit record for an attempted, applied, rolled-back, or undone fix (`PLAN.md` §4.2).
public struct FixJournalEntry: Sendable, Codable, Identifiable, Hashable {
    public var id: String
    public var createdAt: Date
    public var kind: FixKind
    public var planJSON: String
    public var backupDir: String
    public var status: FixJournalStatus
    public var appliedAt: Date?
    public var undoneAt: Date?
    public var error: String?

    public init(
        id: String,
        createdAt: Date,
        kind: FixKind,
        planJSON: String,
        backupDir: String,
        status: FixJournalStatus,
        appliedAt: Date? = nil,
        undoneAt: Date? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.planJSON = planJSON
        self.backupDir = backupDir
        self.status = status
        self.appliedAt = appliedAt
        self.undoneAt = undoneAt
        self.error = error
    }
}
