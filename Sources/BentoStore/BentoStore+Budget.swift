import BentoCore
import Foundation
import GRDB

extension BentoStore {
    /// Persists all `BudgetItem` rows of `budget` for `snapshotID`, replacing any prior rows for the same `(snapshotID, repoPath, agent)`.
    public func saveBudget(_ budget: Budget, snapshotID: String) throws {
        let standardizedFolder =
            budget.folder.isEmpty
            ? nil
            : URL(fileURLWithPath: budget.folder).standardizedFileURL.path
        let repoID = standardizedFolder.map(Self.repoIdentifier(forPath:))

        try dbWriter.write { db in
            if let repoID {
                try db.execute(
                    sql: """
                        DELETE FROM budget_item
                        WHERE snapshot_id = ? AND repo_id = ? AND agent = ?
                        """,
                    arguments: [snapshotID, repoID, budget.agent.rawValue]
                )
            } else {
                try db.execute(
                    sql: """
                        DELETE FROM budget_item
                        WHERE snapshot_id = ? AND repo_id IS NULL AND agent = ?
                        """,
                    arguments: [snapshotID, budget.agent.rawValue]
                )
            }

            for item in budget.items {
                try db.execute(
                    sql: """
                        INSERT INTO budget_item (
                            snapshot_id, repo_id, agent, artifact_id,
                            category, label, tokens, range_lo, range_hi,
                            confidence, method, counts_pre_prompt
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        snapshotID,
                        repoID,
                        budget.agent.rawValue,
                        item.artifactID?.rawValue,
                        item.category.rawValue,
                        item.label,
                        item.tokens,
                        item.range?.lowerBound,
                        item.range?.upperBound,
                        item.confidence.rawValue,
                        item.method,
                        item.countsTowardPrePrompt
                    ]
                )
            }
        }
    }

    /// Fetches persisted `BudgetItem` rows for `(snapshotID, repoPath, agent)` in insertion order.
    public func fetchBudgetItems(
        snapshotID: String,
        repoPath: String?,
        agent: AgentID
    ) throws -> [BudgetItem] {
        let standardizedFolder =
            repoPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let repoID = standardizedFolder.map(Self.repoIdentifier(forPath:))

        return try dbWriter.read { db in
            let rows: [Row]
            if let repoID {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM budget_item
                        WHERE snapshot_id = ? AND repo_id = ? AND agent = ?
                        ORDER BY id ASC
                        """,
                    arguments: [snapshotID, repoID, agent.rawValue]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM budget_item
                        WHERE snapshot_id = ? AND repo_id IS NULL AND agent = ?
                        ORDER BY id ASC
                        """,
                    arguments: [snapshotID, agent.rawValue]
                )
            }

            return try rows.map { row in
                let rowID: Int64 = row["id"]
                let rawCategory: String = row["category"]
                let rawConfidence: String = row["confidence"]
                guard
                    let category = BudgetCategory(rawValue: rawCategory),
                    let confidence = Confidence(rawValue: rawConfidence)
                else {
                    throw BentoStoreError.corruptedPayload(
                        table: "budget_item",
                        column: "category/confidence",
                        id: String(rowID)
                    )
                }

                let artifactIDRaw: String? = row["artifact_id"]
                let range: ClosedRange<Int>?
                if let lo: Int = row["range_lo"], let hi: Int = row["range_hi"], lo <= hi {
                    range = lo...hi
                } else {
                    range = nil
                }

                return BudgetItem(
                    artifactID: artifactIDRaw.map(ArtifactID.init(rawValue:)),
                    category: category,
                    label: row["label"],
                    tokens: row["tokens"],
                    range: range,
                    confidence: confidence,
                    method: row["method"],
                    countsTowardPrePrompt: row["counts_pre_prompt"]
                )
            }
        }
    }
}
