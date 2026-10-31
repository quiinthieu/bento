import BentoAdapters
import BentoCore
import BentoScanner
import BentoTestSupport
import Foundation
import GRDB
import Testing

@testable import BentoStore

struct BentoStoreTests {
    @Test("Migrations create all 12 PLAN §4.2 tables, required columns, indexes, and WAL mode")
    func migrationsCreateCompleteSchemaAndEnableWAL() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-store-schema-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = BentoStore.defaultDatabaseURL(home: tempDir)
        let expectedSuffix = "Library/Application Support/\(Product.supportDirName)/bento.sqlite"
        #expect(dbURL.path.hasSuffix(expectedSuffix))

        let store = try BentoStore(databaseURL: dbURL)
        #expect(store.databaseURL == dbURL)

        let expectedTables: Set<String> = [
            "snapshot",
            "artifact",
            "repo",
            "budget_item",
            "log_file",
            "usage_event",
            "session",
            "calibration",
            "mcp_probe",
            "finding",
            "fix_journal",
            "setting"
        ]

        try store.dbWriter.read { db in
            let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode")?.lowercased()
            #expect(journalMode == "wal")

            let foreignKeys = try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
            #expect(foreignKeys == 1)

            let tableRows = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            )
            let actualTables = Set(tableRows)
            for table in expectedTables {
                #expect(actualTables.contains(table), "Missing §4.2 table: \(table)")
            }

            let expectedColumns: [String: Set<String>] = [
                "snapshot": ["id", "created_at", "home_hash", "scanner_version"],
                "artifact": [
                    "id", "snapshot_id", "agent", "kind", "scope", "name", "path",
                    "real_path", "key_path_json", "content_hash", "enabled",
                    "load_mode_json", "payload_json", "diagnostics_json"
                ],
                "repo": ["id", "path", "display_name", "last_seen_at", "pinned"],
                "budget_item": [
                    "snapshot_id", "repo_id", "agent", "artifact_id", "category",
                    "label", "tokens", "range_lo", "range_hi", "confidence",
                    "method", "counts_pre_prompt"
                ],
                "log_file": [
                    "path", "agent", "size", "mtime", "inode",
                    "offset_consumed", "compressed", "last_error"
                ],
                "usage_event": [
                    "id", "agent", "session_id", "ts", "cwd", "repo_id", "kind",
                    "name", "server", "tool", "input_tokens", "cached_input_tokens",
                    "output_tokens", "turn_index", "model"
                ],
                "session": [
                    "agent", "session_id", "started_at", "cwd",
                    "repo_id", "model", "first_turn_input"
                ],
                "calibration": [
                    "agent", "model", "tokenizer_id", "k_factor",
                    "n_samples", "residual_stddev", "updated_at"
                ],
                "mcp_probe": [
                    "server_config_hash", "agent", "server_name", "probed_at", "ok",
                    "error", "tools_json", "tools_tokens_estimate", "protocol_version"
                ],
                "finding": [
                    "id", "snapshot_id", "kind", "severity",
                    "artifacts_json", "spans_json", "message", "dismissed"
                ],
                "fix_journal": [
                    "id", "created_at", "kind", "plan_json", "backup_dir",
                    "status", "applied_at", "undone_at", "error"
                ],
                "setting": ["key", "value_json"]
            ]

            for (table, requiredCols) in expectedColumns {
                let pragmaRows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                let actualCols = Set(pragmaRows.compactMap { $0["name"] as String? })
                for col in requiredCols {
                    #expect(actualCols.contains(col), "Table '\(table)' missing column '\(col)'")
                }
            }

            let usageIndexes = try Row.fetchAll(db, sql: "PRAGMA index_list(usage_event)")
            var indexedColumnLists: [[String]] = []
            for indexRow in usageIndexes {
                guard let indexName = indexRow["name"] as String? else { continue }
                let infoRows = try Row.fetchAll(db, sql: "PRAGMA index_info(\(indexName))")
                let cols = infoRows.compactMap { $0["name"] as String? }
                indexedColumnLists.append(cols)
            }
            #expect(indexedColumnLists.contains(["agent", "kind", "name", "ts"]))
            #expect(indexedColumnLists.contains(["repo_id", "ts"]))
        }
    }

    @Test("Multiple snapshots persist and round-trip losslessly alongside repo pins, settings, and pruning")
    func snapshotRoundTripRepoPinningSettingsAndRetention() async throws {
        let store = try BentoStore.inMemory()
        let fixture = try FixtureHome(scenario: "polyglot")
        let t1 = Date(timeIntervalSince1970: 1_730_000_000)
        let t2 = Date(timeIntervalSince1970: 1_730_000_600)

        let env1 = fixture.makeEnvironment(now: t1)
        let workspace1 = Workspace(environment: env1, store: store)
        let snap1 = try await workspace1.scanFull()
        #expect(!snap1.artifacts.isEmpty)
        #expect(snap1.repos.count == 1)

        let demoRepoPath = try #require(snap1.repos.first?.path)
        try store.setRepoPinned(path: demoRepoPath, pinned: true, now: t1)
        #expect(try store.pinnedRepoPaths() == [demoRepoPath])

        // Second scan must succeed without PK collision on identical ArtifactIDs and preserve pinned state.
        let env2 = fixture.makeEnvironment(now: t2)
        let workspace2 = Workspace(environment: env2, store: store)
        let snap2 = try await workspace2.scanFull()
        #expect(snap2.id != snap1.id)
        #expect(snap2.repos.first?.isPinned == true)

        let reloaded1 = try #require(try store.loadSnapshot(id: snap1.id))
        let reloaded2 = try #require(try store.loadLatestSnapshot(homeHash: snap2.homeHash))
        #expect(reloaded1 == snap1)
        #expect(reloaded2 == snap2)

        let claudeArtifacts = try store.fetchArtifacts(snapshotID: snap2.id, agent: .claudeCode)
        #expect(!claudeArtifacts.isEmpty)
        #expect(claudeArtifacts.allSatisfy { $0.agent == .claudeCode })

        struct SampleSetting: Codable, Sendable, Equatable {
            var retentionDays: Int
            var keychainRef: String
        }
        let sample = SampleSetting(retentionDays: 180, keychainRef: "anthropic-keychain-item")
        try store.setSetting(sample, forKey: "privacy.retention")
        let loadedSetting = try store.setting(SampleSetting.self, forKey: "privacy.retention")
        #expect(loadedSetting == sample)
        try store.removeSetting(forKey: "privacy.retention")
        #expect(try store.setting(SampleSetting.self, forKey: "privacy.retention") == nil)

        // Retention pruning on usage_event (PLAN §4.2).
        let oldTimestamp = Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSince1970
        let recentTimestamp = Date(timeIntervalSince1970: 1_729_900_000).timeIntervalSince1970
        try await store.dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO usage_event (id, agent, session_id, ts, kind)
                    VALUES ('ev-old', 'claudeCode', 's1', ?, 'sessionStart'),
                           ('ev-new', 'claudeCode', 's2', ?, 'sessionStart')
                    """,
                arguments: [oldTimestamp, recentTimestamp]
            )
        }

        let cutoff = Date(timeIntervalSince1970: 1_720_000_000)
        let prunedCount = try store.pruneUsageEvents(olderThan: cutoff)
        #expect(prunedCount == 1)

        try store.vacuum()
        try store.deleteAllData()
        #expect(try store.loadLatestSnapshot(homeHash: nil) == nil)
        #expect(try store.fetchRepos().isEmpty)
    }

    @Test("Persisted SQLite artifact rows never contain raw secret values (PLAN §7)")
    func sqliteNeverStoresRawSecrets() async throws {
        let store = try BentoStore.inMemory()
        for scenario in ["claude-basic", "copilot-basic"] {
            let fixture = try FixtureHome(scenario: scenario)
            let workspace = Workspace(environment: fixture.makeEnvironment(), store: store)
            let snapshot = try await workspace.scanFull()

            let serializedRows = try await store.dbWriter.read { db in
                try String.fetchAll(
                    db,
                    sql: "SELECT payload_json FROM artifact WHERE snapshot_id = ?",
                    arguments: [snapshot.id]
                )
            }
            #expect(!serializedRows.isEmpty)
            let combined = serializedRows.joined(separator: "\n")
            #expect(!combined.contains("TEST_SYNTHETIC_API_KEY_PLACEHOLDER"))
            #expect(!combined.contains("TEST_SYNTHETIC_COPILOT_PAT_PLACEHOLDER"))
            #expect(!combined.contains("TEST_SYNTHETIC_COPILOT_BEARER"))
        }
    }
}
