import BentoCore
import Foundation
import GRDB

/// Local SQLite store backed by GRDB (`PLAN.md` §4.2, §6.8, §7).
///
/// File-backed instances use `DatabasePool` (SQLite WAL mode) so the macOS app and CLI can safely
/// share the database concurrently. In-memory instances use `DatabaseQueue` for hermetic read-only
/// `--home` runs and tests.
public final class BentoStore: SnapshotPersisting, Sendable {
    /// Default retention window (`180` days) for `usage_event` rows (`PLAN.md` §4.2).
    public static let defaultRetentionDays = 180

    /// On-disk SQLite file URL, or `nil` for an in-memory store.
    public let databaseURL: URL?

    let dbWriter: any DatabaseWriter

    /// Computes `~/Library/Application Support/<Product.supportDirName>/bento.sqlite` relative to `home`.
    public static func defaultDatabaseURL(home: URL) -> URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(Product.supportDirName, isDirectory: true)
            .appendingPathComponent("bento.sqlite", isDirectory: false)
            .standardizedFileURL
    }

    /// Opens or creates an on-disk WAL-mode SQLite database at `databaseURL` and applies migrations.
    public init(databaseURL: URL) throws {
        let standardized = databaseURL.standardizedFileURL
        let parentDir = standardized.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        var config = Configuration()
        config.foreignKeysEnabled = true

        let pool = try DatabasePool(path: standardized.path, configuration: config)
        try BentoMigrations.migrator.migrate(pool)

        self.databaseURL = standardized
        self.dbWriter = pool
    }

    private init(inMemoryQueue: DatabaseQueue) throws {
        try BentoMigrations.migrator.migrate(inMemoryQueue)
        self.databaseURL = nil
        self.dbWriter = inMemoryQueue
    }

    /// Creates an isolated in-memory SQLite store with all §4.2 migrations applied.
    public static func inMemory() throws -> BentoStore {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        return try BentoStore(inMemoryQueue: queue)
    }

    /// Closes underlying SQLite connections and WAL reader queues.
    public func close() throws {
        try dbWriter.close()
    }

    // MARK: - SnapshotPersisting

    private struct ScopedArtifactBatch: Codable {
        var scope: ScanScope
        var artifacts: [Artifact]
    }

    public func saveSnapshot(_ snapshot: Snapshot) throws {
        let encoder = Self.makeJSONEncoder()
        let detectionsJSON = try Self.encodeJSONString(snapshot.detections, using: encoder)
        let scopedBatches = snapshot.scopedArtifacts.keys.sorted().map { scope in
            ScopedArtifactBatch(scope: scope, artifacts: snapshot.scopedArtifacts[scope] ?? [])
        }
        let scopedArtifactsJSON = try Self.encodeJSONString(scopedBatches, using: encoder)
        let resolutionsJSON = try Self.encodeJSONString(snapshot.resolutions, using: encoder)

        try dbWriter.write { db in
            let existingPinnedRows = try String.fetchAll(
                db,
                sql: "SELECT path FROM repo WHERE pinned = 1"
            )
            let pinnedSet = Set(existingPinnedRows)

            var normalizedRepos: [DiscoveredRepo] = []
            normalizedRepos.reserveCapacity(snapshot.repos.count)

            for var repo in snapshot.repos {
                if pinnedSet.contains(repo.path) {
                    repo.isPinned = true
                }
                normalizedRepos.append(repo)

                let repoID = Self.repoIdentifier(forPath: repo.path)
                let sourcesJSON = try Self.encodeJSONString(repo.sources, using: encoder)
                try db.execute(
                    sql: """
                        INSERT INTO repo (id, path, real_path, display_name, last_seen_at, pinned, sources_json)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(path) DO UPDATE SET
                            real_path = excluded.real_path,
                            display_name = excluded.display_name,
                            last_seen_at = excluded.last_seen_at,
                            pinned = MAX(repo.pinned, excluded.pinned),
                            sources_json = excluded.sources_json
                        """,
                    arguments: [
                        repoID,
                        repo.path,
                        repo.realPath,
                        repo.displayName,
                        snapshot.createdAt.timeIntervalSince1970,
                        repo.isPinned,
                        sourcesJSON
                    ]
                )
            }

            let reposJSON = try Self.encodeJSONString(normalizedRepos, using: encoder)

            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO snapshot (
                        id, created_at, home_hash, scanner_version,
                        home_path, detections_json, repos_json,
                        scoped_artifacts_json, resolutions_json
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    snapshot.id,
                    snapshot.createdAt.timeIntervalSince1970,
                    snapshot.homeHash,
                    snapshot.scannerVersion,
                    snapshot.homePath,
                    detectionsJSON,
                    reposJSON,
                    scopedArtifactsJSON,
                    resolutionsJSON
                ]
            )

            try db.execute(
                sql: "DELETE FROM artifact WHERE snapshot_id = ?",
                arguments: [snapshot.id]
            )

            for artifact in snapshot.artifacts {
                let keyPathJSON: String? =
                    if let keyPath = artifact.location.keyPath {
                        try Self.encodeJSONString(keyPath, using: encoder)
                    } else {
                        nil
                    }
                let loadModeJSON = try Self.encodeJSONString(artifact.loadMode, using: encoder)
                let payloadJSON = try Self.encodeJSONString(artifact.payload, using: encoder)
                let diagnosticsJSON = try Self.encodeJSONString(artifact.diagnostics, using: encoder)

                try db.execute(
                    sql: """
                        INSERT INTO artifact (
                            id, snapshot_id, agent, kind, scope, name,
                            path, real_path, key_path_json, content_hash,
                            enabled, load_mode_json, payload_json, diagnostics_json,
                            line_start, line_end
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        artifact.id.rawValue,
                        snapshot.id,
                        artifact.agent.rawValue,
                        artifact.kind.rawValue,
                        artifact.scope.rawValue,
                        artifact.name,
                        artifact.location.path,
                        artifact.location.realPath,
                        keyPathJSON,
                        artifact.contentHash,
                        artifact.enabled,
                        loadModeJSON,
                        payloadJSON,
                        diagnosticsJSON,
                        artifact.location.lineRange?.lowerBound,
                        artifact.location.lineRange?.upperBound
                    ]
                )
            }
        }
    }

    public func loadLatestSnapshot(homeHash: String? = nil) throws -> Snapshot? {
        try dbWriter.read { db in
            let row: Row?
            if let homeHash {
                row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM snapshot
                        WHERE home_hash = ?
                        ORDER BY created_at DESC, rowid DESC
                        LIMIT 1
                        """,
                    arguments: [homeHash]
                )
            } else {
                row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM snapshot
                        ORDER BY created_at DESC, rowid DESC
                        LIMIT 1
                        """
                )
            }
            guard let row else { return nil }
            return try Self.decodeSnapshot(from: row)
        }
    }

    /// Loads a persisted `Snapshot` by its primary key `id`.
    public func loadSnapshot(id: String) throws -> Snapshot? {
        try dbWriter.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM snapshot WHERE id = ?",
                    arguments: [id]
                )
            else {
                return nil
            }
            return try Self.decodeSnapshot(from: row)
        }
    }

    /// Queries relational `artifact` rows for `snapshotID`, optionally filtered by `agent`.
    public func fetchArtifacts(snapshotID: String, agent: AgentID? = nil) throws -> [Artifact] {
        try dbWriter.read { db in
            let rows: [Row]
            if let agent {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM artifact
                        WHERE snapshot_id = ? AND agent = ?
                        ORDER BY rowid ASC
                        """,
                    arguments: [snapshotID, agent.rawValue]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM artifact WHERE snapshot_id = ? ORDER BY rowid ASC",
                    arguments: [snapshotID]
                )
            }
            let decoder = Self.makeJSONDecoder()
            return try rows.map { try Self.decodeArtifact(from: $0, decoder: decoder) }
        }
    }

    // MARK: - Repositories

    /// Fetches all persisted repository rows ordered by `path`.
    public func fetchRepos() throws -> [StoredRepo] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM repo ORDER BY path ASC")
            return rows.map { row in
                StoredRepo(
                    id: row["id"],
                    path: row["path"],
                    realPath: row["real_path"],
                    displayName: row["display_name"],
                    lastSeenAt: Date(timeIntervalSince1970: row["last_seen_at"]),
                    isPinned: row["pinned"]
                )
            }
        }
    }

    public func pinnedRepoPaths() throws -> Set<String> {
        try dbWriter.read { db in
            let paths = try String.fetchAll(db, sql: "SELECT path FROM repo WHERE pinned = 1")
            return Set(paths)
        }
    }

    /// Pins or unpins `path` in the `repo` table, creating the row if needed.
    public func setRepoPinned(
        path: String,
        pinned: Bool,
        displayName: String? = nil,
        now: Date = Date()
    ) throws {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        let repoID = Self.repoIdentifier(forPath: standardized.path)
        let effectiveName = displayName ?? standardized.lastPathComponent

        try dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO repo (id, path, real_path, display_name, last_seen_at, pinned, sources_json)
                    VALUES (?, ?, ?, ?, ?, ?, '["manual"]')
                    ON CONFLICT(path) DO UPDATE SET
                        pinned = excluded.pinned,
                        last_seen_at = excluded.last_seen_at
                    """,
                arguments: [
                    repoID,
                    standardized.path,
                    resolved.path,
                    effectiveName,
                    now.timeIntervalSince1970,
                    pinned
                ]
            )
        }
    }

    // MARK: - Settings

    /// Stores a JSON-encoded setting under `key` (for example Keychain item references, never raw keys).
    public func setSetting<Value: Codable & Sendable>(_ value: Value, forKey key: String) throws {
        let encoder = Self.makeJSONEncoder()
        let jsonString = try Self.encodeJSONString(value, using: encoder)
        try dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO setting (key, value_json)
                    VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json
                    """,
                arguments: [key, jsonString]
            )
        }
    }

    /// Reads and decodes a typed setting stored under `key`, or `nil` if absent.
    public func setting<Value: Codable & Sendable>(
        _ type: Value.Type,
        forKey key: String
    ) throws -> Value? {
        try dbWriter.read { db in
            guard
                let rawJSON = try String.fetchOne(
                    db,
                    sql: "SELECT value_json FROM setting WHERE key = ?",
                    arguments: [key]
                )
            else {
                return nil
            }
            return try Self.decodeJSON(type, from: rawJSON, table: "setting", column: "value_json", id: key)
        }
    }

    /// Removes a setting entry if present.
    public func removeSetting(forKey key: String) throws {
        try dbWriter.write { db in
            try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [key])
        }
    }

    // MARK: - Retention & Lifecycle

    /// Deletes `usage_event` rows older than `cutoff` and returns the number of pruned rows (`PLAN.md` §4.2).
    @discardableResult
    public func pruneUsageEvents(olderThan cutoff: Date) throws -> Int {
        try dbWriter.write { db in
            try db.execute(
                sql: "DELETE FROM usage_event WHERE ts < ?",
                arguments: [cutoff.timeIntervalSince1970]
            )
            return db.changesCount
        }
    }

    /// Compacts the SQLite database file outside a transaction (`PLAN.md` §4.2).
    public func vacuum() throws {
        try dbWriter.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }

    /// Deletes all persisted rows across every table and compacts the SQLite file (`PLAN.md` §7).
    public func deleteAllData() throws {
        try dbWriter.write { db in
            let tables = [
                "artifact",
                "budget_item",
                "finding",
                "snapshot",
                "usage_event",
                "session",
                "log_file",
                "calibration",
                "mcp_probe",
                "fix_journal",
                "repo",
                "setting"
            ]
            for table in tables {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
        try vacuum()
    }

    // MARK: - Decoding Helpers

    static func repoIdentifier(forPath path: String) -> String {
        ContentHasher.sha256Hex(Data(path.utf8))
    }

    private static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func encodeJSONString<T: Encodable>(
        _ value: T,
        using encoder: JSONEncoder
    ) throws -> String {
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeJSON<T: Decodable>(
        _ type: T.Type,
        from raw: String,
        table: String,
        column: String,
        id: String,
        decoder: JSONDecoder = makeJSONDecoder()
    ) throws -> T {
        guard let data = raw.data(using: .utf8) else {
            throw BentoStoreError.corruptedPayload(table: table, column: column, id: id)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw BentoStoreError.corruptedPayload(table: table, column: column, id: id)
        }
    }

    private static func decodeSnapshot(from row: Row) throws -> Snapshot {
        let decoder = makeJSONDecoder()
        let id: String = row["id"]
        let createdAtEpoch: Double = row["created_at"]
        let homeHash: String = row["home_hash"]
        let scannerVersion: String = row["scanner_version"]
        let homePath: String = row["home_path"]
        let detectionsRaw: String = row["detections_json"]
        let reposRaw: String = row["repos_json"]
        let scopedRaw: String = row["scoped_artifacts_json"]
        let resolutionsRaw: String = row["resolutions_json"]

        let detections = try decodeJSON(
            [AgentID: DetectionResult].self,
            from: detectionsRaw,
            table: "snapshot",
            column: "detections_json",
            id: id,
            decoder: decoder
        )
        let repos = try decodeJSON(
            [DiscoveredRepo].self,
            from: reposRaw,
            table: "snapshot",
            column: "repos_json",
            id: id,
            decoder: decoder
        )
        let batches = try decodeJSON(
            [ScopedArtifactBatch].self,
            from: scopedRaw,
            table: "snapshot",
            column: "scoped_artifacts_json",
            id: id,
            decoder: decoder
        )
        let resolutions = try decodeJSON(
            [Resolution].self,
            from: resolutionsRaw,
            table: "snapshot",
            column: "resolutions_json",
            id: id,
            decoder: decoder
        )

        var scopedArtifacts: [ScanScope: [Artifact]] = [:]
        for batch in batches {
            scopedArtifacts[batch.scope] = batch.artifacts
        }

        return Snapshot(
            id: id,
            createdAt: Date(timeIntervalSince1970: createdAtEpoch),
            homePath: homePath,
            homeHash: homeHash,
            scannerVersion: scannerVersion,
            detections: detections,
            repos: repos,
            scopedArtifacts: scopedArtifacts,
            resolutions: resolutions
        )
    }

    private static func decodeArtifact(from row: Row, decoder: JSONDecoder) throws -> Artifact {
        let rawID: String = row["id"]
        let rawAgent: String = row["agent"]
        let rawKind: String = row["kind"]
        let rawScope: Int = row["scope"]
        guard
            let agent = AgentID(rawValue: rawAgent),
            let kind = ArtifactKind(rawValue: rawKind),
            let scope = Scope(rawValue: rawScope)
        else {
            throw BentoStoreError.corruptedPayload(table: "artifact", column: "agent/kind/scope", id: rawID)
        }

        let keyPath: [String]?
        if let keyPathRaw: String = row["key_path_json"] {
            keyPath = try decodeJSON(
                [String].self,
                from: keyPathRaw,
                table: "artifact",
                column: "key_path_json",
                id: rawID,
                decoder: decoder
            )
        } else {
            keyPath = nil
        }

        let lineRange: ClosedRange<Int>?
        if let start: Int = row["line_start"], let end: Int = row["line_end"], start <= end {
            lineRange = start...end
        } else {
            lineRange = nil
        }

        let loadMode = try decodeJSON(
            LoadMode.self,
            from: row["load_mode_json"],
            table: "artifact",
            column: "load_mode_json",
            id: rawID,
            decoder: decoder
        )
        let payload = try decodeJSON(
            ArtifactPayload.self,
            from: row["payload_json"],
            table: "artifact",
            column: "payload_json",
            id: rawID,
            decoder: decoder
        )
        let diagnostics = try decodeJSON(
            [Diagnostic].self,
            from: row["diagnostics_json"],
            table: "artifact",
            column: "diagnostics_json",
            id: rawID,
            decoder: decoder
        )

        return Artifact(
            id: ArtifactID(rawValue: rawID),
            agent: agent,
            kind: kind,
            scope: scope,
            name: row["name"],
            location: SourceLocation(
                path: row["path"],
                realPath: row["real_path"],
                keyPath: keyPath,
                lineRange: lineRange
            ),
            contentHash: row["content_hash"],
            enabled: row["enabled"],
            loadMode: loadMode,
            payload: payload,
            diagnostics: diagnostics
        )
    }
}
