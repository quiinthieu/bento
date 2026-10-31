import BentoCore
import Foundation
import GRDB

extension BentoStore {
    // MARK: - Calibration Persistence (`calibration` table)

    /// Inserts or updates a single `CalibrationRecord` keyed by `(agent, model, tokenizer_id)`.
    public func upsertCalibration(_ record: CalibrationRecord) throws {
        try upsertCalibrations([record])
    }

    /// Inserts or updates multiple `CalibrationRecord` entries atomically.
    public func upsertCalibrations(_ records: [CalibrationRecord]) throws {
        guard !records.isEmpty else { return }
        try dbWriter.write { db in
            for record in records {
                try db.execute(
                    sql: """
                        INSERT INTO calibration (
                            agent, model, tokenizer_id, k_factor,
                            n_samples, residual_stddev, updated_at
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(agent, model, tokenizer_id) DO UPDATE SET
                            k_factor = excluded.k_factor,
                            n_samples = excluded.n_samples,
                            residual_stddev = excluded.residual_stddev,
                            updated_at = excluded.updated_at
                        """,
                    arguments: [
                        record.agent.rawValue,
                        record.model,
                        record.tokenizerID,
                        record.kFactor,
                        record.sampleCount,
                        record.residualStddev,
                        record.updatedAt.timeIntervalSince1970
                    ]
                )
            }
        }
    }

    /// Fetches persisted `CalibrationRecord` rows ordered deterministically by `(agent, model, tokenizer_id)`.
    public func calibrations(for agent: AgentID? = nil) throws -> [CalibrationRecord] {
        try dbWriter.read { db in
            let rows: [Row]
            if let agent {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM calibration
                        WHERE agent = ?
                        ORDER BY agent ASC, model ASC, tokenizer_id ASC
                        """,
                    arguments: [agent.rawValue]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM calibration ORDER BY agent ASC, model ASC, tokenizer_id ASC"
                )
            }
            return try rows.map { row in
                let rawAgent: String = row["agent"]
                let model: String = row["model"]
                guard let parsedAgent = AgentID(rawValue: rawAgent) else {
                    throw BentoStoreError.corruptedPayload(
                        table: "calibration",
                        column: "agent",
                        id: "\(rawAgent):\(model)"
                    )
                }
                return CalibrationRecord(
                    agent: parsedAgent,
                    model: model,
                    tokenizerID: row["tokenizer_id"],
                    kFactor: row["k_factor"],
                    sampleCount: row["n_samples"],
                    residualStddev: row["residual_stddev"],
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"])
                )
            }
        }
    }

    // MARK: - Calibration Samples & Measured First-Turn Input Lookup

    /// Fetches `SessionRecord` rows eligible for calibration (`first_turn_input != nil` and non-empty `cwd`).
    public func calibrationSessions(
        agent: AgentID? = nil,
        since: Date? = nil,
        until: Date? = nil
    ) throws -> [SessionRecord] {
        try dbWriter.read { db in
            var clauses = ["first_turn_input IS NOT NULL", "cwd IS NOT NULL", "cwd != ''"]
            var args: [any DatabaseValueConvertible] = []
            if let agent {
                clauses.append("agent = ?")
                args.append(agent.rawValue)
            }
            if let since {
                clauses.append("started_at >= ?")
                args.append(since.timeIntervalSince1970)
            }
            if let until {
                clauses.append("started_at <= ?")
                args.append(until.timeIntervalSince1970)
            }
            let whereSQL = "WHERE " + clauses.joined(separator: " AND ")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM session
                    \(whereSQL)
                    ORDER BY started_at ASC, agent ASC, session_id ASC
                    """,
                arguments: StatementArguments(args)
            )
            return try rows.map { try Self.decodeSessionRecord(from: $0) }
        }
    }

    /// Computes the median `first_turn_input` observed in `session` rows for `(agent, repoPath)`
    /// (`PLAN.md` §4.1 `Budget.measuredFirstTurnInput`, §6.3, §11 T12).
    public func measuredFirstTurnMedianInput(
        agent: AgentID,
        repoPath: String,
        model: String? = nil,
        since: Date? = nil,
        until: Date? = nil
    ) throws -> Int? {
        let normalizedRepoPath = URL(fileURLWithPath: repoPath).standardizedFileURL.path
        let resolvedRepoPath = URL(fileURLWithPath: normalizedRepoPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        return try dbWriter.read { db in
            let repoCandidates = try Self.fetchRepoCandidates(in: db)
            let targetRepoID = Self.matchRepoID(forCwd: normalizedRepoPath, against: repoCandidates)

            func matchesRepo(rowRepoID: String?, rowCwd: String?) -> Bool {
                if let targetRepoID, rowRepoID == targetRepoID {
                    return true
                }
                guard let rowCwd, !rowCwd.isEmpty else { return false }
                let stdCwd = URL(fileURLWithPath: rowCwd).standardizedFileURL.path
                let realCwd = URL(fileURLWithPath: rowCwd).resolvingSymlinksInPath().standardizedFileURL.path
                for candidate in Set([normalizedRepoPath, resolvedRepoPath]) {
                    if stdCwd == candidate || stdCwd.hasPrefix(candidate + "/")
                        || realCwd == candidate || realCwd.hasPrefix(candidate + "/")
                    {
                        return true
                    }
                }
                return false
            }

            var clauses = ["agent = ?", "first_turn_input IS NOT NULL"]
            var args: [any DatabaseValueConvertible] = [agent.rawValue]
            if let since {
                clauses.append("started_at >= ?")
                args.append(since.timeIntervalSince1970)
            }
            if let until {
                clauses.append("started_at <= ?")
                args.append(until.timeIntervalSince1970)
            }

            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM session WHERE \(clauses.joined(separator: " AND "))",
                arguments: StatementArguments(args)
            )

            var allRepoInputs: [Int] = []
            var modelFilteredInputs: [Int] = []
            let normalizedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            for row in rows {
                let sess = try Self.decodeSessionRecord(from: row)
                guard let firstTurn = sess.firstTurnInput,
                    matchesRepo(rowRepoID: sess.repoID, rowCwd: sess.cwd)
                else {
                    continue
                }
                allRepoInputs.append(firstTurn)
                if let normalizedModel, !normalizedModel.isEmpty,
                    sess.model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedModel
                {
                    modelFilteredInputs.append(firstTurn)
                }
            }

            let chosen = !modelFilteredInputs.isEmpty ? modelFilteredInputs : allRepoInputs
            guard !chosen.isEmpty else { return nil }
            let sorted = chosen.sorted()
            if sorted.count % 2 == 1 {
                return sorted[sorted.count / 2]
            }
            let hi = sorted.count / 2
            return (sorted[hi - 1] + sorted[hi]) / 2
        }
    }
}
