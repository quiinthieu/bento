import BentoCore
import Foundation
import GRDB

/// Stored `Finding` row paired with its owning `snapshotID` and user `isDismissed` flag (`PLAN.md` §4.2).
public struct PersistedFinding: Sendable, Codable, Hashable {
    public var snapshotID: String
    public var finding: Finding
    public var isDismissed: Bool

    public init(snapshotID: String, finding: Finding, isDismissed: Bool = false) {
        self.snapshotID = snapshotID
        self.finding = finding
        self.isDismissed = isDismissed
    }
}

extension BentoStore {
    // MARK: - Findings Persistence (`finding` table)

    /// Persists `findings` under `snapshotID`, optionally replacing existing findings of `replacingKind`
    /// while preserving any previously set `dismissed = 1` flag for matching deterministic `finding.id`s.
    public func saveFindings(
        _ findings: [Finding],
        snapshotID: String,
        replacingKind kindFilter: Finding.Kind? = nil
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        try dbWriter.write { db in
            // Remember all previously dismissed deterministic finding IDs (across snapshots or within this snapshot)
            // before deleting replaced rows so user dismissals survive re-scans.
            let dismissedRows = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT id FROM finding WHERE dismissed = 1"
            )
            let previouslyDismissedIDs = Set(dismissedRows)

            if let kindFilter {
                try db.execute(
                    sql: "DELETE FROM finding WHERE snapshot_id = ? AND kind = ?",
                    arguments: [snapshotID, kindFilter.rawValue]
                )
            }

            for finding in findings {
                let artifactsJSON = String(decoding: try encoder.encode(finding.artifacts), as: UTF8.self)
                let spansJSON = String(decoding: try encoder.encode(finding.spans), as: UTF8.self)
                let fixesJSON = String(decoding: try encoder.encode(finding.suggestedFixes), as: UTF8.self)
                let isDismissed = previouslyDismissedIDs.contains(finding.id)

                try db.execute(
                    sql: """
                        INSERT INTO finding (
                            id, snapshot_id, kind, severity,
                            artifacts_json, spans_json, suggested_fixes_json,
                            message, dismissed
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(snapshot_id, id) DO UPDATE SET
                            kind = excluded.kind,
                            severity = excluded.severity,
                            artifacts_json = excluded.artifacts_json,
                            spans_json = excluded.spans_json,
                            suggested_fixes_json = excluded.suggested_fixes_json,
                            message = excluded.message,
                            dismissed = MAX(finding.dismissed, excluded.dismissed)
                        """,
                    arguments: [
                        finding.id,
                        snapshotID,
                        finding.kind.rawValue,
                        Self.severityInt(for: finding.severity),
                        artifactsJSON,
                        spansJSON,
                        fixesJSON,
                        finding.message,
                        isDismissed
                    ]
                )
            }
        }
    }

    /// Marks a persisted finding as dismissed or active. When `snapshotID == nil`, updates all snapshots carrying `id`.
    public func setFindingDismissed(id: String, snapshotID: String? = nil, dismissed: Bool) throws {
        try dbWriter.write { db in
            if let snapshotID {
                try db.execute(
                    sql: "UPDATE finding SET dismissed = ? WHERE snapshot_id = ? AND id = ?",
                    arguments: [dismissed, snapshotID, id]
                )
            } else {
                try db.execute(
                    sql: "UPDATE finding SET dismissed = ? WHERE id = ?",
                    arguments: [dismissed, id]
                )
            }
        }
    }

    /// Fetches persisted `Finding` records for `snapshotID`, excluding dismissed findings by default.
    public func fetchFindings(
        snapshotID: String,
        kind: Finding.Kind? = nil,
        includeDismissed: Bool = false
    ) throws -> [Finding] {
        let persisted = try fetchPersistedFindings(snapshotID: snapshotID, kind: kind)
        if includeDismissed {
            return persisted.map(\.finding)
        }
        return persisted.filter { !$0.isDismissed }.map(\.finding)
    }

    /// Fetches `PersistedFinding` records (including `isDismissed` metadata) ordered deterministically by
    /// `(severity DESC, kind ASC, id ASC)`.
    public func fetchPersistedFindings(
        snapshotID: String,
        kind: Finding.Kind? = nil
    ) throws -> [PersistedFinding] {
        let decoder = JSONDecoder()
        return try dbWriter.read { db in
            var clauses = ["snapshot_id = ?"]
            var args: [any DatabaseValueConvertible] = [snapshotID]
            if let kind {
                clauses.append("kind = ?")
                args.append(kind.rawValue)
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM finding
                    WHERE \(clauses.joined(separator: " AND "))
                    ORDER BY severity DESC, kind ASC, id ASC
                    """,
                arguments: StatementArguments(args)
            )
            return try rows.map { row in
                try Self.decodePersistedFinding(from: row, decoder: decoder)
            }
        }
    }

    // MARK: - Private Encoding / Decoding Helpers

    private static func severityInt(for severity: Severity) -> Int {
        switch severity {
        case .info:
            return 0
        case .warning:
            return 1
        case .error:
            return 2
        }
    }

    private static func severity(from rawInt: Int) throws -> Severity {
        switch rawInt {
        case 0:
            return .info
        case 1:
            return .warning
        case 2:
            return .error
        default:
            throw BentoStoreError.corruptedPayload(table: "finding", column: "severity", id: "\(rawInt)")
        }
    }

    private static func decodePersistedFinding(from row: Row, decoder: JSONDecoder) throws -> PersistedFinding {
        let id: String = row["id"]
        let snapshotID: String = row["snapshot_id"]
        let rawKind: String = row["kind"]
        let rawSeverity: Int = row["severity"]
        guard let kind = Finding.Kind(rawValue: rawKind) else {
            throw BentoStoreError.corruptedPayload(table: "finding", column: "kind", id: id)
        }
        let severity = try Self.severity(from: rawSeverity)

        let artifactsRaw: String = row["artifacts_json"]
        let spansRaw: String = row["spans_json"]
        let fixesRaw: String = row["suggested_fixes_json"] ?? "[]"

        guard
            let artifactsData = artifactsRaw.data(using: .utf8),
            let spansData = spansRaw.data(using: .utf8),
            let fixesData = fixesRaw.data(using: .utf8),
            let artifacts = try? decoder.decode([ArtifactID].self, from: artifactsData),
            let spans = try? decoder.decode([SourceLocation].self, from: spansData),
            let suggestedFixes = try? decoder.decode([FixKind].self, from: fixesData)
        else {
            throw BentoStoreError.corruptedPayload(table: "finding", column: "json", id: id)
        }

        let finding = Finding(
            id: id,
            kind: kind,
            severity: severity,
            artifacts: artifacts,
            spans: spans,
            message: row["message"],
            suggestedFixes: suggestedFixes
        )
        let isDismissed: Bool = row["dismissed"]
        return PersistedFinding(snapshotID: snapshotID, finding: finding, isDismissed: isDismissed)
    }
}
