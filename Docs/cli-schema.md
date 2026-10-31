# CLI JSON Output Schema (`schemaVersion: 1`)

This document specifies the versioned `--json` output contract for the companion CLI (`Product.cliName`, default `bentoctx`), per `PLAN.md` §6.8 and §11 (T07).

## Envelope & Encoding Conventions

1. **Schema version:** Every `--json` response is a top-level JSON object carrying `"schemaVersion": 1` (`Int`) and `"command": "<subcommand>"` (`String`).
2. **Deterministic formatting:** Output is UTF-8 JSON formatted with sorted object keys (`.sortedKeys`) and 2-space indentation (`.prettyPrinted`), followed by a trailing newline.
3. **Timestamps:** All `Date` fields (`generatedAt`, `createdAt`) are encoded as ISO-8601 UTC strings (`YYYY-MM-DDTHH:MM:SSZ`).
4. **Optional fields:** Optional filter fields (`agentFilter`, `repoFilter`) are omitted when `null`, matching Swift `Codable` synthesis across `BentoCore` domain models.
5. **Secret redaction:** Secrets are redacted at parse time (`"«redacted»"` in `SettingsDoc`; keys-only `envKeys` in `MCPServerConfig`). Raw secret values never appear in CLI JSON or SQLite (`PLAN.md` §7).
6. **Store sharing & hermetic `--home`:**
   - When `--db <path>` (or `BENTO_DB_PATH`) is supplied, commands read and write snapshots in that SQLite WAL database.
   - When `--home <path>` is supplied without `--db`, commands use an in-memory store so inspecting an arbitrary or read-only directory performs zero disk writes.
   - When neither `--home` nor `--db` is supplied, commands share `~/Library/Application Support/<Product.supportDirName>/bento.sqlite` in WAL mode with the macOS app.

---

## `scan --json`

Runs full agent detection, repository discovery (`PLAN.md` §5.3), global + per-repo artifact discovery, and precedence resolution across all supported adapters, persisting the resulting `Snapshot`.

```bash
bentoctx scan [--home PATH] [--db PATH] --json
```

### Top-Level Fields

| Field | Type | Description |
|---|---|---|
| `schemaVersion` | `Int` | Always `1`. |
| `command` | `String` | Always `"scan"`. |
| `generatedAt` | `String` | ISO-8601 UTC timestamp when the response was emitted. |
| `snapshotID` | `String` | Unique identifier of the persisted `Snapshot`. |
| `createdAt` | `String` | ISO-8601 UTC timestamp when the `Snapshot` was captured. |
| `scannerVersion` | `String` | Marketing version (`Product.version`). |
| `homePath` | `String` | Standardized target home directory path. |
| `homeHash` | `String` | Lowercase SHA-256 hex digest of `homePath`. |
| `detections` | `Object<AgentID, DetectionResult>` | Map keyed by `AgentID` raw value (`claudeCode`, `codex`, `gemini`, `copilot`, `cursor`, `windsurf`). |
| `repos` | `Array<DiscoveredRepo>` | Deduplicated discovered repositories (`path`, `realPath`, `displayName`, `sources` such as `claudeLogs`/`codexLogs`/`geminiLogs`/`copilotLogs`, `isPinned`). |
| `artifactCount` | `Int` | Count of distinct artifacts across global and discovered repository scopes. |
| `agentCounts` | `Object<AgentID, Int>` | Count of distinct artifacts per `AgentID`. |
| `resolutionCount` | `Int` | Total `(agent, repo)` resolution records computed in the snapshot. |

---

## `inventory --json`

Lists discovered `Artifact` records from the active or newly scanned `Snapshot`, optionally filtered by `--agent` and/or `--repo`.

```bash
bentoctx inventory [--home PATH] [--db PATH] [--agent AGENT] [--repo PATH] --json
```

### Top-Level Fields

| Field | Type | Description |
|---|---|---|
| `schemaVersion` | `Int` | Always `1`. |
| `command` | `String` | Always `"inventory"`. |
| `generatedAt` | `String` | ISO-8601 UTC timestamp when the response was emitted. |
| `snapshotID` | `String` | Identifier of the `Snapshot` backing this inventory query. |
| `agentFilter` | `String?` | Canonical `AgentID` raw value when `--agent` was specified; omitted otherwise. |
| `repoFilter` | `String?` | Standardized repository path when `--repo` was specified; omitted otherwise. |
| `artifacts` | `Array<Artifact>` | Deterministically ordered `BentoCore.Artifact` records matching the filters. |

---

## `resolve --json`

Computes or retrieves the effective load-order `Resolution` (including `ordered`, `shadowed` with reasons, and `warnings`) for a specific `--agent` when launched in `--repo`.

```bash
bentoctx resolve [--home PATH] [--db PATH] --repo PATH --agent AGENT --json
```

### Top-Level Fields

| Field | Type | Description |
|---|---|---|
| `schemaVersion` | `Int` | Always `1`. |
| `command` | `String` | Always `"resolve"`. |
| `generatedAt` | `String` | ISO-8601 UTC timestamp when the response was emitted. |
| `snapshotID` | `String` | Identifier of the `Snapshot` backing this resolution (or on-demand scan). |
| `agent` | `String` | Canonical `AgentID` raw value (`claudeCode`, `codex`, `gemini`, `copilot`, `cursor`, `windsurf`). |
| `repoPath` | `String` | Standardized target folder path. |
| `artifacts` | `Array<Artifact>` | All global and workspace `BentoCore.Artifact` records considered during resolution, allowing direct lookup of `artifactID` references in `resolution.ordered` and `resolution.shadowed`. |
| `resolution` | `Resolution` | `BentoCore.Resolution` (`agent`, `folder`, `ordered`, `shadowed`, `warnings`). |

---

## `budget --json`

Computes pre-prompt and deferred/on-invoke/conditional context token `Budget` breakdowns across all budget-capable agents (`claudeCode`, `codex`, `gemini`, `copilot`), or for a single `--agent`, when launched in `--repo`. Automatically applies fitted least-squares log calibrations (`calibration` table) when at least 3 session samples exist and attaches `measuredFirstTurnInput` (median logged first-turn input tokens for `(agent, repo)`). Passing `--probe-mcp <NAME>` (repeatable or comma-separated; `'*'` for all active servers) grants explicit consent for the named server(s), probes them over a scrubbed 15 s stdio/HTTP session, and caches schemas in SQLite by `server_config_hash`. Passing `--api anthropic|gemini` opts into exact provider token-count APIs using keys stored in macOS Keychain.

```bash
bentoctx budget [--home PATH] [--db PATH] --repo PATH [--agent AGENT] [--model MODEL] [--probe-mcp NAME]... [--api PROVIDER]... --json
```

### Top-Level Fields

| Field | Type | Description |
|---|---|---|
| `schemaVersion` | `Int` | Always `1`. |
| `command` | `String` | Always `"budget"`. |
| `generatedAt` | `String` | ISO-8601 UTC timestamp when the response was emitted. |
| `snapshotID` | `String` | Identifier of the `Snapshot` backing this budget query (or on-demand scan). |
| `repoPath` | `String` | Standardized target repository or working directory path. |
| `agentFilter` | `String?` | Canonical `AgentID` raw value when `--agent` was specified; omitted otherwise. |
| `modelOverride` | `String?` | Explicit `--model` override when supplied; omitted otherwise. |
| `budgets` | `Array<Budget>` | Deterministically ordered `BentoCore.Budget` records (`agent`, `folder`, `model`, `items`, `measuredFirstTurnInput`, `contextWindow`). Every `BudgetItem` carries `confidence`, `method`, and `countsTowardPrePrompt`. |

---

## `ingest --json`

Incrementally ingests local agent session logs (`.jsonl`, legacy `.json`, and Zstandard-compressed `.jsonl.zst`) into `BentoStore`, advancing `log_file.offset_consumed` past complete newlines, handling inode/truncation log rotation, and persisting privacy-safe `UsageEvent` and `SessionRecord` rows (`PLAN.md` §6.2, §6.8, §11 T11).

```bash
bentoctx ingest [--home PATH] [--db PATH] [--agent AGENT] [--reset] --json
```

### Top-Level Fields

| Field | Type | Description |
|---|---|---|
| `schemaVersion` | `Int` | Always `1`. |
| `command` | `String` | Always `"ingest"`. |
| `generatedAt` | `String` | ISO-8601 UTC timestamp when the response was emitted. |
| `agentFilter` | `String?` | Canonical `AgentID` raw value when `--agent` was specified; omitted otherwise. |
| `didReset` | `Bool` | `true` when `--reset` cleared previous `log_file`, `session`, and `usage_event` rows prior to ingestion. |
| `filesDiscovered` | `Int` | Total log files discovered across matching adapters. |
| `filesIngested` | `Int` | Number of changed or new log files read during this pass. |
| `filesSkippedUnchanged` | `Int` | Number of unchanged log files skipped by `(offset_consumed, inode)` or `.zst` `(size, mtime, inode)` check. |
| `bytesRead` | `Int` | Total newly consumed bytes read in this pass. |
| `eventsDecoded` | `Int` | Total `UsageEvent` records decoded from read bytes. |
| `eventsInserted` | `Int` | Net new `usage_event` rows inserted after deterministic `(agent, session_id, event_uid)` deduplication. |
| `sessionsUpdated` | `Int` | Number of `session` rows created or updated. |
| `decoderErrors` | `Int` | Count of malformed JSON lines skipped without failing the run. |
| `diagnostics` | `Array<Diagnostic>` | Non-fatal ingestion diagnostics (`ingest.lineOversized`, `ingest.zstdTruncated`, `ingest.zstdCorrupt`). |

---

## `usage --json`

Aggregates privacy-safe `session` and `usage_event` records over a rolling `--days` lookback window (default `30`), optionally filtered by `--repo` and/or `--agent`, joins active resolved artifacts ranked by `"cost × unused"`, and emits `Finding.Kind.unused` records for 0-invocation skills, MCP servers, and subagents in repositories with at least `--min-sessions` (default `5`) sessions.

```bash
bentoctx usage [--home PATH] [--db PATH] [--days N] [--min-sessions M] [--repo PATH] [--agent AGENT] --json
```

### Top-Level Fields

| Field | Type | Description |
|---|---|---|
| `schemaVersion` | `Int` | Always `1`. |
| `command` | `String` | Always `"usage"`. |
| `generatedAt` | `String` | ISO-8601 UTC timestamp when the response was emitted. |
| `days` | `Int` | Lookback window in days. |
| `minimumSessions` | `Int` | Minimum session threshold (`--min-sessions`, default `5`) required before flagging 0-invocation items as `unused`. |
| `since` | `String` | ISO-8601 UTC window start timestamp. |
| `until` | `String` | ISO-8601 UTC window end timestamp. |
| `agentFilter` | `String?` | Canonical `AgentID` raw value when `--agent` was specified; omitted otherwise. |
| `repoFilter` | `String?` | Standardized repository path when `--repo` was specified; omitted otherwise. |
| `sessionCount` | `Int` | Matching distinct sessions across the selected window and filters. |
| `eventCount` | `Int` | Matching `usage_event` count across the selected window and filters. |
| `tokenTotals` | `UsageTokenTotals` | Aggregate `inputTokens`, `cachedInputTokens`, `outputTokens`, and `turnCount`. |
| `byAgent` | `Array<AgentUsageSummary>` | Per-agent breakdowns (`sessionCount`, `turnCount`, token sums, `firstTurnMedianInput`, and `skills` / `mcpTools` / `subagents` / `commands` / `builtinTools` invocation summaries). |
| `artifactUsage` | `Array<ArtifactUsageJoin>` | Active resolved invokable artifacts (`.mcpServer`, `.skill`, `.subagent`, `.command`) joined with `tokensCostPerSession`, `invocationCount`, `lastUsedAt`, and `costTimesUnusedScore`, sorted descending by `"cost × unused"`. |
| `unusedFindings` | `Array<Finding>` | Deterministic `Finding` records (`kind == "unused"`) for 0-invocation pre-prompt-cost-bearing items in repositories with `>= minimumSessions` sessions. |

---

## `hygiene --json`

Audits rules and configuration hygiene across discovered agents and repositories (`PLAN.md` §6.5, §6.8, §11 T13): exact and MinHash-LSH near-duplicate rule units, identical non-symlinked skill directories, block-level `>= 70%` `@AGENTS.md` import suggestions, deterministic opposing-directive conflicts (`Resources/hygiene/conflicts.yaml`), size/truncation limits (Windsurf 6,000 / 12,000 character caps, Codex `project_doc_max_bytes`, `@import` max depth, and `--max-rule-tokens`), broken `@import` directives, and malformed JSON/TOML/YAML configurations. When `--fail-on warning` or `--fail-on error` is set and at least one finding reaches that severity, the CLI still prints the full JSON response to `stdout` and exits with status `1`.

```bash
bentoctx hygiene [--home PATH] [--db PATH] [--repo PATH] [--agent AGENT] [--fail-on warning|error] [--max-rule-tokens N] --json
```

### Top-Level Fields

| Field | Type | Description |
|---|---|---|
| `schemaVersion` | `Int` | Always `1`. |
| `command` | `String` | Always `"hygiene"`. |
| `generatedAt` | `String` | ISO-8601 UTC timestamp when the response was emitted. |
| `snapshotID` | `String` | Identifier of the `Snapshot` backing this hygiene audit. |
| `agentFilter` | `String?` | Canonical `AgentID` raw value when `--agent` was specified; omitted otherwise. |
| `repoFilter` | `String?` | Standardized repository path when `--repo` was specified; omitted otherwise. |
| `failOn` | `String?` | Threshold (`"warning"` or `"error"`) when `--fail-on` was specified; omitted otherwise. |
| `findingCount` | `Int` | Total findings returned. |
| `errorCount` | `Int` | Count of `.error`-severity findings. |
| `warningCount` | `Int` | Count of `.warning`-severity findings. |
| `infoCount` | `Int` | Count of `.info`-severity findings. |
| `findings` | `Array<Finding>` | Deterministically ordered `BentoCore.Finding` records (`id`, `kind`, `severity`, `artifacts`, `spans` with 1-based `lineRange`, `message`, `suggestedFixes`). |

---

## Reserved Subcommand Envelopes (M4)

Upcoming commands (`fix`, `undo`) share the same `"schemaVersion": 1`, `"command": "<name>"`, `"generatedAt": "<ISO-8601>"` envelope and will be documented here as task T14 lands.
