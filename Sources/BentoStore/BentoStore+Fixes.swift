import BentoCore
import Foundation
import GRDB

extension BentoStore {
    /// Well-known `setting` table key for the master `"Allow changes"` gate (`PLAN.md` §6.6).
    public static let allowChangesSettingKey = "fixes.allowChanges"

    /// Well-known `setting` table key for overriding the canonical consolidated skills directory (`PLAN.md` §6.6, §6.7).
    public static let canonicalSkillsDirectorySettingKey = "fixes.canonicalSkillsDirectory"

    // MARK: - Fix Journal

    /// Upserts a `FixJournalEntry` into `fix_journal`.
    public func saveFixJournalEntry(_ entry: FixJournalEntry) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fix_journal (
                        id, created_at, kind, plan_json, backup_dir,
                        status, applied_at, undone_at, error
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        created_at = excluded.created_at,
                        kind = excluded.kind,
                        plan_json = excluded.plan_json,
                        backup_dir = excluded.backup_dir,
                        status = excluded.status,
                        applied_at = excluded.applied_at,
                        undone_at = excluded.undone_at,
                        error = excluded.error
                    """,
                arguments: [
                    entry.id,
                    entry.createdAt.timeIntervalSince1970,
                    entry.kind.rawValue,
                    entry.planJSON,
                    entry.backupDir,
                    entry.status.rawValue,
                    entry.appliedAt?.timeIntervalSince1970,
                    entry.undoneAt?.timeIntervalSince1970,
                    entry.error
                ]
            )
        }
    }

    /// Loads a single `FixJournalEntry` by its identifier, or `nil` if absent.
    public func fetchFixJournalEntry(id: String) throws -> FixJournalEntry? {
        try dbWriter.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM fix_journal WHERE id = ?",
                    arguments: [id]
                )
            else {
                return nil
            }
            return try Self.decodeFixJournalRow(row)
        }
    }

    /// Loads recent `FixJournalEntry` records ordered newest-first.
    public func fetchFixJournalEntries(limit: Int = 100) throws -> [FixJournalEntry] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM fix_journal
                    ORDER BY created_at DESC, rowid DESC
                    LIMIT ?
                    """,
                arguments: [max(1, limit)]
            )
            return try rows.map(Self.decodeFixJournalRow)
        }
    }

    // MARK: - Fix Settings

    /// Returns whether the master `"Allow changes"` toggle is enabled (defaults to `false`).
    public func allowChangesEnabled() throws -> Bool {
        try setting(Bool.self, forKey: Self.allowChangesSettingKey) ?? false
    }

    /// Persists the master `"Allow changes"` toggle state.
    public func setAllowChangesEnabled(_ enabled: Bool) throws {
        try setSetting(enabled, forKey: Self.allowChangesSettingKey)
    }

    /// Returns the configured canonical skills directory override, or `nil` to use `<home>/.agents/skills`.
    public func canonicalSkillsDirectory() throws -> String? {
        try setting(String.self, forKey: Self.canonicalSkillsDirectorySettingKey)
    }

    /// Sets or clears the canonical skills directory override.
    public func setCanonicalSkillsDirectory(_ path: String?) throws {
        if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try setSetting(path, forKey: Self.canonicalSkillsDirectorySettingKey)
        } else {
            try removeSetting(forKey: Self.canonicalSkillsDirectorySettingKey)
        }
    }

    private static func decodeFixJournalRow(_ row: Row) throws -> FixJournalEntry {
        let id: String = row["id"]
        let rawKind: String = row["kind"]
        let rawStatus: String = row["status"]
        guard
            let kind = FixKind(rawValue: rawKind),
            let status = FixJournalStatus(rawValue: rawStatus)
        else {
            throw BentoStoreError.corruptedPayload(
                table: "fix_journal",
                column: "kind/status",
                id: id
            )
        }

        let createdAtEpoch: Double = row["created_at"]
        let appliedEpoch: Double? = row["applied_at"]
        let undoneEpoch: Double? = row["undone_at"]

        return FixJournalEntry(
            id: id,
            createdAt: Date(timeIntervalSince1970: createdAtEpoch),
            kind: kind,
            planJSON: row["plan_json"],
            backupDir: row["backup_dir"],
            status: status,
            appliedAt: appliedEpoch.map { Date(timeIntervalSince1970: $0) },
            undoneAt: undoneEpoch.map { Date(timeIntervalSince1970: $0) },
            error: row["error"]
        )
    }
}
