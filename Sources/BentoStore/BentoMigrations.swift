import GRDB

/// Schema migrations for the local SQLite database (`PLAN.md` §4.2).
public enum BentoMigrations: Sendable {
    /// Configured GRDB `DatabaseMigrator` defining all `PLAN.md` §4.2 tables and indexes.
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial_schema") { db in
            try db.execute(
                sql: """
                    CREATE TABLE snapshot (
                        id TEXT PRIMARY KEY NOT NULL,
                        created_at DOUBLE NOT NULL,
                        home_hash TEXT NOT NULL,
                        scanner_version TEXT NOT NULL,
                        home_path TEXT NOT NULL,
                        detections_json TEXT NOT NULL,
                        repos_json TEXT NOT NULL,
                        scoped_artifacts_json TEXT NOT NULL,
                        resolutions_json TEXT NOT NULL
                    );
                    CREATE INDEX idx_snapshot_home_created ON snapshot(home_hash, created_at DESC);

                    CREATE TABLE artifact (
                        id TEXT NOT NULL,
                        snapshot_id TEXT NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
                        agent TEXT NOT NULL,
                        kind TEXT NOT NULL,
                        scope INTEGER NOT NULL,
                        name TEXT NOT NULL,
                        path TEXT NOT NULL,
                        real_path TEXT NOT NULL,
                        key_path_json TEXT,
                        content_hash TEXT NOT NULL,
                        enabled BOOLEAN NOT NULL,
                        load_mode_json TEXT NOT NULL,
                        payload_json TEXT NOT NULL,
                        diagnostics_json TEXT NOT NULL,
                        line_start INTEGER,
                        line_end INTEGER,
                        PRIMARY KEY (snapshot_id, id)
                    );
                    CREATE INDEX idx_artifact_snapshot_agent ON artifact(snapshot_id, agent);

                    CREATE TABLE repo (
                        id TEXT PRIMARY KEY NOT NULL,
                        path TEXT NOT NULL UNIQUE,
                        real_path TEXT NOT NULL,
                        display_name TEXT NOT NULL,
                        last_seen_at DOUBLE NOT NULL,
                        pinned BOOLEAN NOT NULL DEFAULT 0,
                        sources_json TEXT NOT NULL DEFAULT '[]'
                    );

                    CREATE TABLE budget_item (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        snapshot_id TEXT NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
                        repo_id TEXT,
                        agent TEXT NOT NULL,
                        artifact_id TEXT,
                        category TEXT NOT NULL,
                        label TEXT NOT NULL,
                        tokens INTEGER NOT NULL,
                        range_lo INTEGER,
                        range_hi INTEGER,
                        confidence TEXT NOT NULL,
                        method TEXT NOT NULL,
                        counts_pre_prompt BOOLEAN NOT NULL
                    );

                    CREATE TABLE log_file (
                        path TEXT PRIMARY KEY NOT NULL,
                        agent TEXT NOT NULL,
                        size INTEGER NOT NULL,
                        mtime DOUBLE NOT NULL,
                        inode INTEGER NOT NULL,
                        offset_consumed INTEGER NOT NULL,
                        compressed BOOLEAN NOT NULL DEFAULT 0,
                        last_error TEXT
                    );

                    CREATE TABLE usage_event (
                        id TEXT PRIMARY KEY NOT NULL,
                        agent TEXT NOT NULL,
                        session_id TEXT NOT NULL,
                        ts DOUBLE NOT NULL,
                        cwd TEXT,
                        repo_id TEXT,
                        kind TEXT NOT NULL,
                        name TEXT,
                        server TEXT,
                        tool TEXT,
                        input_tokens INTEGER,
                        cached_input_tokens INTEGER,
                        output_tokens INTEGER,
                        turn_index INTEGER,
                        model TEXT
                    );
                    CREATE INDEX idx_usage_event_agent_kind_name_ts
                        ON usage_event(agent, kind, name, ts);
                    CREATE INDEX idx_usage_event_repo_ts
                        ON usage_event(repo_id, ts);

                    CREATE TABLE session (
                        agent TEXT NOT NULL,
                        session_id TEXT NOT NULL,
                        started_at DOUBLE NOT NULL,
                        cwd TEXT,
                        repo_id TEXT,
                        model TEXT,
                        first_turn_input INTEGER,
                        PRIMARY KEY (agent, session_id)
                    );

                    CREATE TABLE calibration (
                        agent TEXT NOT NULL,
                        model TEXT NOT NULL,
                        tokenizer_id TEXT NOT NULL,
                        k_factor DOUBLE NOT NULL,
                        n_samples INTEGER NOT NULL,
                        residual_stddev DOUBLE NOT NULL,
                        updated_at DOUBLE NOT NULL,
                        PRIMARY KEY (agent, model, tokenizer_id)
                    );

                    CREATE TABLE mcp_probe (
                        server_config_hash TEXT PRIMARY KEY NOT NULL,
                        agent TEXT NOT NULL,
                        server_name TEXT NOT NULL,
                        probed_at DOUBLE NOT NULL,
                        ok BOOLEAN NOT NULL,
                        error TEXT,
                        tools_json TEXT NOT NULL,
                        tools_tokens_estimate INTEGER NOT NULL,
                        protocol_version TEXT
                    );

                    CREATE TABLE finding (
                        id TEXT NOT NULL,
                        snapshot_id TEXT NOT NULL REFERENCES snapshot(id) ON DELETE CASCADE,
                        kind TEXT NOT NULL,
                        severity INTEGER NOT NULL,
                        artifacts_json TEXT NOT NULL,
                        spans_json TEXT NOT NULL,
                        message TEXT NOT NULL,
                        dismissed BOOLEAN NOT NULL DEFAULT 0,
                        PRIMARY KEY (snapshot_id, id)
                    );

                    CREATE TABLE fix_journal (
                        id TEXT PRIMARY KEY NOT NULL,
                        created_at DOUBLE NOT NULL,
                        kind TEXT NOT NULL,
                        plan_json TEXT NOT NULL,
                        backup_dir TEXT NOT NULL,
                        status TEXT NOT NULL,
                        applied_at DOUBLE,
                        undone_at DOUBLE,
                        error TEXT
                    );

                    CREATE TABLE setting (
                        key TEXT PRIMARY KEY NOT NULL,
                        value_json TEXT NOT NULL
                    );
                    """
            )
        }

        migrator.registerMigration("v2_log_file_decoder_state") { db in
            try db.execute(sql: "ALTER TABLE log_file ADD COLUMN decoder_state BLOB")
        }

        return migrator
    }
}
