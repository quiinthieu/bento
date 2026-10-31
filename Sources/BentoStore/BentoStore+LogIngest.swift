import BentoCore
import Foundation
import GRDB

extension BentoStore: LogIngestPersisting {
    // MARK: - Log File Cursor Persistence

    public func logFileState(forPath path: String) throws -> LogFileState? {
        let stdPath = URL(fileURLWithPath: path).standardizedFileURL.path
        return try dbWriter.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM log_file WHERE path = ?",
                    arguments: [stdPath]
                )
            else {
                return nil
            }
            return try Self.decodeLogFileState(from: row)
        }
    }

    /// Fetches all persisted `log_file` cursor states ordered by `path`.
    public func logFileStates() throws -> [LogFileState] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM log_file ORDER BY path ASC")
            return try rows.map { try Self.decodeLogFileState(from: $0) }
        }
    }

    // MARK: - Repo Linking

    /// Upserts discovered repositories into `repo` without requiring a full snapshot scan so standalone
    /// `bentoctx ingest` invocations immediately link `usage_event.repo_id` and `session.repo_id`.
    public func syncDiscoveredRepos(_ repos: [DiscoveredRepo], seenAt: Date) throws {
        guard !repos.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        try dbWriter.write { db in
            for repo in repos {
                let repoID = Self.repoIdentifier(forPath: repo.path)
                let sourcesJSON = String(decoding: try encoder.encode(repo.sources), as: UTF8.self)
                try db.execute(
                    sql: """
                        INSERT INTO repo (id, path, real_path, display_name, last_seen_at, pinned, sources_json)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(path) DO UPDATE SET
                            real_path = excluded.real_path,
                            display_name = excluded.display_name,
                            last_seen_at = MAX(repo.last_seen_at, excluded.last_seen_at),
                            pinned = MAX(repo.pinned, excluded.pinned),
                            sources_json = excluded.sources_json
                        """,
                    arguments: [
                        repoID,
                        repo.path,
                        repo.realPath,
                        repo.displayName,
                        seenAt.timeIntervalSince1970,
                        repo.isPinned,
                        sourcesJSON
                    ]
                )
            }
        }
    }

    public func resolveRepoID(forCwd cwd: String?) throws -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return try dbWriter.read { db in
            let repoRows = try Self.fetchRepoCandidates(in: db)
            return Self.matchRepoID(forCwd: cwd, against: repoRows)
        }
    }

    public func existingEventCountsBySession(agent: AgentID, sessionIDs: Set<String>) throws -> [String: Int] {
        guard !sessionIDs.isEmpty else { return [:] }
        return try dbWriter.read { db in
            var result: [String: Int] = [:]
            for sessionID in sessionIDs {
                let count =
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM usage_event WHERE agent = ? AND session_id = ?",
                        arguments: [agent.rawValue, sessionID]
                    ) ?? 0
                result[sessionID] = count
            }
            return result
        }
    }

    // MARK: - Atomic Batch Persistence & Reset

    @discardableResult
    public func recordIngestedLogBatch(_ batch: IngestedLogBatch) throws -> PersistedBatchCounts {
        try dbWriter.write { db in
            let repoCandidates = try Self.fetchRepoCandidates(in: db)
            var repoCache: [String: String?] = [:]

            func lookupRepoID(for rawCwd: String?) -> String? {
                guard let rawCwd, !rawCwd.isEmpty else { return nil }
                if let cached = repoCache[rawCwd] {
                    return cached
                }
                let matched = Self.matchRepoID(forCwd: rawCwd, against: repoCandidates)
                repoCache[rawCwd] = matched
                return matched
            }

            var eventsInserted = 0
            for stored in batch.events {
                let event = stored.event
                let resolvedRepoID = stored.repoID ?? lookupRepoID(for: event.cwd)
                let cols = Self.columns(for: event.kind, fallbackModel: stored.model)

                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO usage_event (
                            id, agent, session_id, ts, cwd, repo_id,
                            kind, name, server, tool,
                            input_tokens, cached_input_tokens, output_tokens,
                            turn_index, model
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        stored.id,
                        event.agent.rawValue,
                        event.sessionID,
                        event.timestamp.timeIntervalSince1970,
                        event.cwd,
                        resolvedRepoID,
                        cols.kind,
                        cols.name,
                        cols.server,
                        cols.tool,
                        cols.inputTokens,
                        cols.cachedInputTokens,
                        cols.outputTokens,
                        cols.turnIndex,
                        cols.model
                    ]
                )
                if db.changesCount > 0 {
                    eventsInserted += 1
                }
            }

            var sessionsUpdated = 0
            for session in batch.sessions {
                let resolvedRepoID = session.repoID ?? lookupRepoID(for: session.cwd)
                try db.execute(
                    sql: """
                        INSERT INTO session (
                            agent, session_id, started_at, cwd, repo_id, model, first_turn_input
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(agent, session_id) DO UPDATE SET
                            started_at = MIN(session.started_at, excluded.started_at),
                            cwd = COALESCE(session.cwd, excluded.cwd),
                            repo_id = COALESCE(session.repo_id, excluded.repo_id),
                            model = COALESCE(excluded.model, session.model),
                            first_turn_input = COALESCE(session.first_turn_input, excluded.first_turn_input)
                        """,
                    arguments: [
                        session.agent.rawValue,
                        session.sessionID,
                        session.startedAt.timeIntervalSince1970,
                        session.cwd,
                        resolvedRepoID,
                        session.model,
                        session.firstTurnInput
                    ]
                )
                sessionsUpdated += 1
            }

            let state = batch.fileState
            try db.execute(
                sql: """
                    INSERT INTO log_file (
                        path, agent, size, mtime, inode, offset_consumed,
                        compressed, last_error, decoder_state
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(path) DO UPDATE SET
                        agent = excluded.agent,
                        size = excluded.size,
                        mtime = excluded.mtime,
                        inode = excluded.inode,
                        offset_consumed = excluded.offset_consumed,
                        compressed = excluded.compressed,
                        last_error = excluded.last_error,
                        decoder_state = excluded.decoder_state
                    """,
                arguments: [
                    state.path,
                    state.agent.rawValue,
                    Int64(bitPattern: state.size),
                    state.mtime.timeIntervalSince1970,
                    Int64(bitPattern: state.inode),
                    Int64(bitPattern: state.offsetConsumed),
                    state.isCompressed,
                    state.lastError,
                    state.decoderState
                ]
            )

            return PersistedBatchCounts(
                eventsInserted: eventsInserted,
                sessionsUpdated: sessionsUpdated
            )
        }
    }

    public func resetLogIngestState() throws {
        try dbWriter.write { db in
            try db.execute(sql: "DELETE FROM usage_event")
            try db.execute(sql: "DELETE FROM session")
            try db.execute(sql: "DELETE FROM log_file")
        }
    }

    // MARK: - Queries & Usage Aggregation

    /// Fetches persisted `SessionRecord` rows ordered deterministically by `(started_at, agent, session_id)`.
    public func allSessions(agent: AgentID? = nil, repoID: String? = nil) throws -> [SessionRecord] {
        try dbWriter.read { db in
            var clauses: [String] = []
            var args: [any DatabaseValueConvertible] = []
            if let agent {
                clauses.append("agent = ?")
                args.append(agent.rawValue)
            }
            if let repoID {
                clauses.append("repo_id = ?")
                args.append(repoID)
            }
            let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
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

    /// Fetches persisted `StoredUsageEvent` rows ordered deterministically by `(ts, agent, session_id, id)`.
    public func allUsageEvents(
        agent: AgentID? = nil,
        since: Date? = nil,
        until: Date? = nil
    ) throws -> [StoredUsageEvent] {
        try dbWriter.read { db in
            var clauses: [String] = []
            var args: [any DatabaseValueConvertible] = []
            if let agent {
                clauses.append("agent = ?")
                args.append(agent.rawValue)
            }
            if let since {
                clauses.append("ts >= ?")
                args.append(since.timeIntervalSince1970)
            }
            if let until {
                clauses.append("ts <= ?")
                args.append(until.timeIntervalSince1970)
            }
            let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM usage_event
                    \(whereSQL)
                    ORDER BY ts ASC, agent ASC, session_id ASC, id ASC
                    """,
                arguments: StatementArguments(args)
            )
            return try rows.map { try Self.decodeStoredUsageEvent(from: $0) }
        }
    }

    /// Aggregates `usage_event` and `session` rows over `[since, until]` with optional `agent` and `repoPath` filters.
    public func usageSummary(
        since: Date,
        until: Date,
        agent: AgentID? = nil,
        repoPath: String? = nil
    ) throws -> UsageSummary {
        let normalizedRepoPath = repoPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let resolvedRepoPath = normalizedRepoPath.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
        }

        return try dbWriter.read { db in
            let repoCandidates = try Self.fetchRepoCandidates(in: db)
            let targetRepoID: String? =
                if let normalizedRepoPath {
                    Self.matchRepoID(forCwd: normalizedRepoPath, against: repoCandidates)
                } else {
                    nil
                }

            func matchesRepoFilter(rowRepoID: String?, rowCwd: String?) -> Bool {
                guard let normalizedRepoPath else { return true }
                if let targetRepoID, rowRepoID == targetRepoID {
                    return true
                }
                guard let rowCwd, !rowCwd.isEmpty else { return false }
                let stdCwd = URL(fileURLWithPath: rowCwd).standardizedFileURL.path
                let realCwd = URL(fileURLWithPath: rowCwd).resolvingSymlinksInPath().standardizedFileURL.path
                for repoCandidate in Set([normalizedRepoPath, resolvedRepoPath ?? normalizedRepoPath]) {
                    if stdCwd == repoCandidate || stdCwd.hasPrefix(repoCandidate + "/")
                        || realCwd == repoCandidate || realCwd.hasPrefix(repoCandidate + "/")
                    {
                        return true
                    }
                }
                return false
            }

            var eventSQL = "SELECT * FROM usage_event WHERE ts >= ? AND ts <= ?"
            var eventArgs: [any DatabaseValueConvertible] = [
                since.timeIntervalSince1970,
                until.timeIntervalSince1970
            ]
            if let agent {
                eventSQL += " AND agent = ?"
                eventArgs.append(agent.rawValue)
            }
            eventSQL += " ORDER BY ts ASC, agent ASC, session_id ASC, id ASC"

            let rawEventRows = try Row.fetchAll(db, sql: eventSQL, arguments: StatementArguments(eventArgs))
            let matchingEvents: [StoredUsageEvent] = try rawEventRows.compactMap { row in
                let decoded = try Self.decodeStoredUsageEvent(from: row)
                guard matchesRepoFilter(rowRepoID: decoded.repoID, rowCwd: decoded.event.cwd) else {
                    return nil
                }
                return decoded
            }

            var sessionSQL = "SELECT * FROM session"
            var sessionArgs: [any DatabaseValueConvertible] = []
            if let agent {
                sessionSQL += " WHERE agent = ?"
                sessionArgs.append(agent.rawValue)
            }
            sessionSQL += " ORDER BY started_at ASC, agent ASC, session_id ASC"
            let allSessionRows = try Row.fetchAll(db, sql: sessionSQL, arguments: StatementArguments(sessionArgs))

            var eventSessionKeys: Set<String> = []
            for ev in matchingEvents {
                eventSessionKeys.insert("\(ev.event.agent.rawValue)|\(ev.event.sessionID)")
            }

            var matchingSessions: [SessionRecord] = []
            for row in allSessionRows {
                let sess = try Self.decodeSessionRecord(from: row)
                let key = "\(sess.agent.rawValue)|\(sess.sessionID)"
                let inWindow = sess.startedAt >= since && sess.startedAt <= until
                guard
                    eventSessionKeys.contains(key)
                        || (inWindow && matchesRepoFilter(rowRepoID: sess.repoID, rowCwd: sess.cwd))
                else {
                    continue
                }
                matchingSessions.append(sess)
            }

            var globalTokens = UsageTokenTotals()
            var sessionsByAgent: [AgentID: [SessionRecord]] = [:]
            for sess in matchingSessions {
                sessionsByAgent[sess.agent, default: []].append(sess)
            }
            var eventsByAgent: [AgentID: [StoredUsageEvent]] = [:]
            for ev in matchingEvents {
                eventsByAgent[ev.event.agent, default: []].append(ev)
            }

            let candidateAgents: [AgentID] =
                if let agent {
                    [agent]
                } else {
                    AgentID.allCases.filter {
                        !(sessionsByAgent[$0] ?? []).isEmpty || !(eventsByAgent[$0] ?? []).isEmpty
                    }
                }

            var byAgent: [AgentUsageSummary] = []
            for agentID in candidateAgents {
                let agentSessions = sessionsByAgent[agentID] ?? []
                let agentEvents = eventsByAgent[agentID] ?? []

                var turnCount = 0
                var inputSum = 0
                var cachedSum = 0
                var outputSum = 0

                var skillsMap: [String: (count: Int, last: Date)] = [:]
                var mcpMap: [String: (server: String, tool: String, count: Int, last: Date)] = [:]
                var subagentsMap: [String: (count: Int, last: Date)] = [:]
                var commandsMap: [String: (count: Int, last: Date)] = [:]
                var builtinsMap: [String: (count: Int, last: Date)] = [:]

                for stored in agentEvents {
                    let ts = stored.event.timestamp
                    switch stored.event.kind {
                    case .sessionStart:
                        break
                    case .tokenUsage(let input, let cached, let output, _):
                        turnCount += 1
                        inputSum += input
                        cachedSum += (cached ?? 0)
                        outputSum += output
                    case .skillInvoked(let name):
                        Self.bumpNamed(&skillsMap, name: name, ts: ts)
                    case .mcpToolCalled(let server, let tool):
                        let key = "\(server)\u{0}\(tool)"
                        if let prev = mcpMap[key] {
                            mcpMap[key] = (server, tool, prev.count + 1, max(prev.last, ts))
                        } else {
                            mcpMap[key] = (server, tool, 1, ts)
                        }
                    case .subagentInvoked(let name):
                        Self.bumpNamed(&subagentsMap, name: name, ts: ts)
                    case .commandInvoked(let name):
                        Self.bumpNamed(&commandsMap, name: name, ts: ts)
                    case .builtinToolCalled(let name):
                        Self.bumpNamed(&builtinsMap, name: name, ts: ts)
                    }
                }

                globalTokens.turnCount += turnCount
                globalTokens.inputTokens += inputSum
                globalTokens.cachedInputTokens += cachedSum
                globalTokens.outputTokens += outputSum

                let firstTurnSamples = agentSessions.compactMap(\.firstTurnInput).sorted()
                let medianFirstTurn: Int?
                if firstTurnSamples.isEmpty {
                    medianFirstTurn = nil
                } else if firstTurnSamples.count % 2 == 1 {
                    medianFirstTurn = firstTurnSamples[firstTurnSamples.count / 2]
                } else {
                    let hi = firstTurnSamples.count / 2
                    medianFirstTurn = (firstTurnSamples[hi - 1] + firstTurnSamples[hi]) / 2
                }

                byAgent.append(
                    AgentUsageSummary(
                        agent: agentID,
                        sessionCount: agentSessions.count,
                        turnCount: turnCount,
                        inputTokens: inputSum,
                        cachedInputTokens: cachedSum,
                        outputTokens: outputSum,
                        firstTurnMedianInput: medianFirstTurn,
                        skills: Self.sortedInvocations(skillsMap),
                        mcpTools: mcpMap.values
                            .map {
                                MCPToolInvocationSummary(
                                    server: $0.server,
                                    tool: $0.tool,
                                    count: $0.count,
                                    lastUsedAt: $0.last
                                )
                            }
                            .sorted {
                                if $0.count != $1.count { return $0.count > $1.count }
                                if $0.server != $1.server { return $0.server < $1.server }
                                return $0.tool < $1.tool
                            },
                        subagents: Self.sortedInvocations(subagentsMap),
                        commands: Self.sortedInvocations(commandsMap),
                        builtinTools: Self.sortedInvocations(builtinsMap)
                    )
                )
            }

            return UsageSummary(
                since: since,
                until: until,
                agentFilter: agent,
                repoFilter: normalizedRepoPath,
                sessionCount: matchingSessions.count,
                eventCount: matchingEvents.count,
                tokenTotals: globalTokens,
                byAgent: byAgent
            )
        }
    }

    // MARK: - Private Row Mapping Helpers

    private struct RepoCandidate {
        var id: String
        var path: String
        var realPath: String
    }

    private struct EventRowColumns {
        var kind: String
        var name: String?
        var server: String?
        var tool: String?
        var inputTokens: Int?
        var cachedInputTokens: Int?
        var outputTokens: Int?
        var turnIndex: Int?
        var model: String?
    }

    private static func columns(for kind: UsageEvent.Kind, fallbackModel: String?) -> EventRowColumns {
        switch kind {
        case .sessionStart(let startModel):
            return EventRowColumns(kind: "sessionStart", model: startModel ?? fallbackModel)
        case .tokenUsage(let input, let cached, let output, let turnIdx):
            return EventRowColumns(
                kind: "tokenUsage",
                inputTokens: input,
                cachedInputTokens: cached,
                outputTokens: output,
                turnIndex: turnIdx,
                model: fallbackModel
            )
        case .skillInvoked(let name):
            return EventRowColumns(kind: "skillInvoked", name: name, model: fallbackModel)
        case .mcpToolCalled(let server, let tool):
            return EventRowColumns(
                kind: "mcpToolCalled",
                name: "\(server)/\(tool)",
                server: server,
                tool: tool,
                model: fallbackModel
            )
        case .subagentInvoked(let name):
            return EventRowColumns(kind: "subagentInvoked", name: name, model: fallbackModel)
        case .commandInvoked(let name):
            return EventRowColumns(kind: "commandInvoked", name: name, model: fallbackModel)
        case .builtinToolCalled(let name):
            return EventRowColumns(kind: "builtinToolCalled", name: name, model: fallbackModel)
        }
    }

    private static func fetchRepoCandidates(in db: Database) throws -> [RepoCandidate] {
        let rows = try Row.fetchAll(db, sql: "SELECT id, path, real_path FROM repo")
        return rows.map {
            RepoCandidate(
                id: $0["id"],
                path: $0["path"],
                realPath: $0["real_path"]
            )
        }
    }

    private static func matchRepoID(forCwd rawCwd: String, against candidates: [RepoCandidate]) -> String? {
        guard !candidates.isEmpty else { return nil }
        let stdCwd = URL(fileURLWithPath: rawCwd).standardizedFileURL.path
        let realCwd = URL(fileURLWithPath: rawCwd).resolvingSymlinksInPath().standardizedFileURL.path

        var bestID: String?
        var bestLength = -1

        for candidate in candidates {
            for repoRoot in [candidate.path, candidate.realPath] where !repoRoot.isEmpty {
                let matched =
                    stdCwd == repoRoot
                    || stdCwd.hasPrefix(repoRoot + "/")
                    || realCwd == repoRoot
                    || realCwd.hasPrefix(repoRoot + "/")
                if matched && repoRoot.count > bestLength {
                    bestLength = repoRoot.count
                    bestID = candidate.id
                }
            }
        }
        return bestID
    }

    private static func decodeLogFileState(from row: Row) throws -> LogFileState {
        let path: String = row["path"]
        let rawAgent: String = row["agent"]
        guard let agent = AgentID(rawValue: rawAgent) else {
            throw BentoStoreError.corruptedPayload(table: "log_file", column: "agent", id: path)
        }
        let rawSize: Int64 = row["size"]
        let mtimeEpoch: Double = row["mtime"]
        let rawInode: Int64 = row["inode"]
        let rawOffset: Int64 = row["offset_consumed"]
        let compressed: Bool = row["compressed"]
        let lastError: String? = row["last_error"]
        let decoderState: Data? = row["decoder_state"]

        return LogFileState(
            path: path,
            agent: agent,
            size: UInt64(bitPattern: rawSize),
            mtime: Date(timeIntervalSince1970: mtimeEpoch),
            inode: UInt64(bitPattern: rawInode),
            offsetConsumed: UInt64(bitPattern: rawOffset),
            isCompressed: compressed,
            lastError: lastError,
            decoderState: decoderState
        )
    }

    private static func decodeSessionRecord(from row: Row) throws -> SessionRecord {
        let rawAgent: String = row["agent"]
        let sessionID: String = row["session_id"]
        guard let agent = AgentID(rawValue: rawAgent) else {
            throw BentoStoreError.corruptedPayload(table: "session", column: "agent", id: sessionID)
        }
        return SessionRecord(
            agent: agent,
            sessionID: sessionID,
            startedAt: Date(timeIntervalSince1970: row["started_at"]),
            cwd: row["cwd"],
            repoID: row["repo_id"],
            model: row["model"],
            firstTurnInput: row["first_turn_input"]
        )
    }

    private static func decodeStoredUsageEvent(from row: Row) throws -> StoredUsageEvent {
        let id: String = row["id"]
        let rawAgent: String = row["agent"]
        guard let agent = AgentID(rawValue: rawAgent) else {
            throw BentoStoreError.corruptedPayload(table: "usage_event", column: "agent", id: id)
        }
        let sessionID: String = row["session_id"]
        let tsEpoch: Double = row["ts"]
        let cwd: String? = row["cwd"]
        let repoID: String? = row["repo_id"]
        let rawKind: String = row["kind"]
        let model: String? = row["model"]

        let kind: UsageEvent.Kind
        switch rawKind {
        case "sessionStart":
            kind = .sessionStart(model: model)
        case "tokenUsage":
            let input: Int = row["input_tokens"] ?? 0
            let cached: Int? = row["cached_input_tokens"]
            let output: Int = row["output_tokens"] ?? 0
            let turnIndex: Int = row["turn_index"] ?? 0
            kind = .tokenUsage(input: input, cachedInput: cached, output: output, turnIndex: turnIndex)
        case "skillInvoked":
            guard let name: String = row["name"] else {
                throw BentoStoreError.corruptedPayload(table: "usage_event", column: "name", id: id)
            }
            kind = .skillInvoked(name: name)
        case "mcpToolCalled":
            guard let server: String = row["server"], let tool: String = row["tool"] else {
                throw BentoStoreError.corruptedPayload(table: "usage_event", column: "server/tool", id: id)
            }
            kind = .mcpToolCalled(server: server, tool: tool)
        case "subagentInvoked":
            guard let name: String = row["name"] else {
                throw BentoStoreError.corruptedPayload(table: "usage_event", column: "name", id: id)
            }
            kind = .subagentInvoked(name: name)
        case "commandInvoked":
            guard let name: String = row["name"] else {
                throw BentoStoreError.corruptedPayload(table: "usage_event", column: "name", id: id)
            }
            kind = .commandInvoked(name: name)
        case "builtinToolCalled":
            guard let name: String = row["name"] else {
                throw BentoStoreError.corruptedPayload(table: "usage_event", column: "name", id: id)
            }
            kind = .builtinToolCalled(name: name)
        default:
            throw BentoStoreError.corruptedPayload(table: "usage_event", column: "kind", id: id)
        }

        return StoredUsageEvent(
            id: id,
            event: UsageEvent(
                agent: agent,
                sessionID: sessionID,
                timestamp: Date(timeIntervalSince1970: tsEpoch),
                cwd: cwd,
                kind: kind
            ),
            repoID: repoID,
            model: model
        )
    }

    private static func bumpNamed(
        _ dict: inout [String: (count: Int, last: Date)],
        name: String,
        ts: Date
    ) {
        if let prev = dict[name] {
            dict[name] = (prev.count + 1, max(prev.last, ts))
        } else {
            dict[name] = (1, ts)
        }
    }

    private static func sortedInvocations(
        _ dict: [String: (count: Int, last: Date)]
    ) -> [InvocationSummary] {
        dict
            .map { InvocationSummary(name: $0.key, count: $0.value.count, lastUsedAt: $0.value.last) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.name < $1.name
            }
    }
}
