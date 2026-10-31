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

Computes pre-prompt and deferred/on-invoke/conditional context token `Budget` breakdowns across all budget-capable agents (`claudeCode`, `codex`, `gemini`, `copilot`), or for a single `--agent`, when launched in `--repo`.

```bash
bentoctx budget [--home PATH] [--db PATH] --repo PATH [--agent AGENT] [--model MODEL] --json
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

## Reserved Subcommand Envelopes (M2–M4)

Upcoming commands (`usage`, `hygiene`, `fix`, `undo`, `ingest`) share the same `"schemaVersion": 1`, `"command": "<name>"`, `"generatedAt": "<ISO-8601>"` envelope and will be documented here as tasks T10–T14 land.
