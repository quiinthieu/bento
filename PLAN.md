# Bento: Implementation Plan (v1)

> **Placeholder name:** "Bento" is a working title. The display name, bundle ID, CLI binary name and app-support folder all come from one file, `Config/Product.xcconfig` plus `Sources/BentoCore/Product.swift` (`Product.name`, `Product.bundleID`, `Product.cliName`, `Product.supportDirName`). **Don't hardcode "Bento" anywhere else.**

Bento is a native macOS app, with a companion CLI, that audits and manages the configuration AI coding agents load: Claude Code, Codex CLI, Gemini CLI and Copilot CLI, plus Cursor and Windsurf for inventory and rules only. It answers three questions for any folder:
1. **What does each agent load here, and in what precedence?**
2. **How many tokens does that cost before I type anything?**
3. **Which of those tokens do I actually use, and what can I safely trim?**

---

## Repository & workflow

- **Repo:** [`quiinthieu/bento`](https://github.com/quiinthieu/bento) (`git@github.com:quiinthieu/bento.git`). It's empty: no branches or commits yet.
- **Bootstrap (first agent only):**
  ```sh
  git clone git@github.com:quiinthieu/bento.git && cd bento
  git checkout -b main
  # add PLAN.md, AGENTS.md (+ CLAUDE.md containing "@AGENTS.md"), .gitignore (Swift/Xcode/.build/DerivedData/.DS_Store)
  git add . && git commit -m "chore: add implementation plan and agent instructions"
  git push -u origin main
  ```
  Then set `main` as the default branch and protect it (PR required, CI green) on GitHub.
- **Per task:** branch from latest `main` as `task/TNN-short-slug` (e.g. `task/T01-skeleton`), one task per branch, Conventional Commits (`feat:`, `fix:`, `test:`, `chore:`, `docs:`), open a PR titled `TNN: <task title>` that lists the acceptance criteria as a checklist, squash-merge once CI passes, delete the branch.
- **CI:** T01 adds `.github/workflows/ci.yml` (macOS runner: `swift build`, `swift test`, `Scripts/lint-writes.sh`, `swift format lint`). T16 adds `release.yml` on `v*` tags.
- **Never** force-push `main` or commit secrets, signing certificates or notarization credentials (use GitHub Actions secrets).

## 0. Instructions for agents (read first)

You are an AI coding agent (Claude Code, Codex, etc.) building this project. Follow these rules strictly:

1. **Work one task at a time, in order.** Pick the lowest-numbered task in §11 that isn't marked `[x]`. Don't start the next task until the current one passes all its acceptance criteria. If a task is too big, split it into sub-tasks in this file before you start, and keep the original ID as a prefix (e.g. `T05a`).
2. **Write tests first.** For every task, write failing tests in `Tests/` against fixtures in `Fixtures/`, then implement until they pass. Every PR/commit must leave `swift test` green.
3. **Never write to real user config.** Only `BentoFixes` may write, move, symlink or trash files outside the app's own support directory. Every other module opens files read-only. Tests must never touch the real `$HOME`. Use the `Environment.home` injection with fixture homes (§9). A CI lint (T01) fails the build if `FileManager` write APIs, `Data.write`, `String.write`, `FileHandle(forWriting…)`, `createSymbolicLink`, `trashItem` or `removeItem` show up outside `Sources/BentoFixes` and `Sources/BentoStore`.
4. **Never execute MCP servers implicitly.** Launching a server to call `tools/list` happens only after explicit per-server user consent (UI toggle or `--probe-mcp <name>` CLI flag), with a timeout and a scrubbed environment (§6.4).
5. **No network calls** except (a) optional token-count APIs when the user supplied a key and enabled them, and (b) Sparkle update checks if enabled (M5). No telemetry, crash reporting or analytics, ever.
6. **All agent file paths and formats are assumptions.** Each one in §5 is marked *(verify against current docs)*. Before you implement an adapter, check the agent's current official docs and the installed CLI's behaviour. Record what you found (doc URL and date) in `Docs/adapters/<agent>.md`, and update this plan if anything differs. Put every path in the adapter's `PathCatalog` so a change only touches one place.
7. **Keep modules honest.** Respect the dependency graph in §3. `BentoCore` must not import SwiftUI, GRDB or any adapter.
8. **Swift 6 strict concurrency** (`-strict-concurrency=complete`), with no `@unchecked Sendable` unless it's justified in a comment. No force-unwraps outside tests.
9. **Small commits** with conventional-commit messages (`feat(adapters-claude): …`). Update the task checkbox in §11 and add a line to `CHANGELOG.md` when a task is done.
10. **When you're unsure, choose read-only and labelled-estimate.** Never present an estimate as exact.
11. **Don't add dependencies** beyond §3.3 without writing the reason down in `Docs/decisions/NNN-*.md` (ADR).

---

## 1. Goals & non-goals

### Goals (v1)
- **G1 Inventory:** a read-only, precedence-resolved view of every config artifact (settings, rules/memory files, skills, MCP servers, subagents, commands, hooks, plugins), global and per repo, for Claude Code, Codex CLI, Gemini CLI and Copilot CLI. Cursor and Windsurf get inventory and the rules audit only.
- **G2 Context Budget:** per repo and per agent, a stacked bar of the pre-prompt tokens by category. Each item is labelled **exact**, **estimated** or **measured**.
- **G3 Usage join:** invocation counts per skill, MCP tool and subagent, parsed from local session logs. Example: "costs ~X tokens/session, used 0 times in N days".
- **G4 Rules hygiene:** near-duplicate and conflict detection across AGENTS.md, CLAUDE.md, GEMINI.md, `.cursor/rules`, Copilot instructions and Windsurf rules, plus warnings for Windsurf's size limits.
- **G5 Safe reversible fixes:** disable a skill or MCP server, consolidate duplicate skills via symlinks, and replace duplicated rules with `@AGENTS.md` imports. Each fix gets a diff preview, a backup and an undo, and deletions go to the Trash. The app is **read-only by default**.
- **G6 CLI:** `bentoctx` CLI that shares Core, giving scriptable JSON output for inventory, budget, usage and hygiene.
- **G7 Distribution:** notarized Developer ID app delivered as a DMG and Homebrew cask. macOS 15+, Apple Silicon and Intel (universal).

### Non-goals (v1)
- Not an App Store app. No sandbox (we need to read `~/.claude`, `~/.codex` and similar).
- No cloud, accounts, sync or telemetry.
- No editing of arbitrary config: only the fixed set of fixes in §6.6.
- No agent runtime proxying or prompt compression.
- No Windows or Linux GUI (the CLI may build on Linux later, but that isn't a v1 requirement).
- Nothing from the v2 backlog (§13).

### Success metrics
- Scanning a home folder with 4 agents and around 50 repos finishes in under 3 s cold and under 300 ms warm.
- Offline budget estimates land within ±15% of the measured first-turn input tokens after calibration (per agent, on the fixture corpus and the developer's own machine).
- Zero writes outside Fixes, proven by the lint and by a test that runs a full scan against a read-only fixture home (`chmod -R a-w`).

---

## 2. Glossary
- **Artifact:** any file or config entry an agent loads (rule file, skill, MCP server, subagent, command, hook, setting, plugin).
- **Scope:** `managed/enterprise` > `user/global` > `project` (shared) > `project-local` > `directory` (nested). The order varies by agent, and each adapter defines it.
- **Resolution:** the ordered, merged set of artifacts an agent would load when started in folder F.
- **Pre-prompt budget:** the tokens in the context before the user's first message (system prompt, tool schemas, rules, skill frontmatter, etc.).
- **Confidence:** `exact` (counted by the provider API, or a known-exact tokenizer for that model), `estimated` (offline tokenizer/heuristic, possibly calibrated), `measured` (derived from logged usage numbers).

---

## 3. Architecture

### 3.1 Targets (Swift Package Manager)
```
BentoCore        Pure models, protocols, precedence, path utils. No I/O beyond protocols.
BentoParsing     JSON(C)/TOML/YAML-frontmatter/Markdown/.mdc parsers, @import resolver.
BentoAdapters    One sub-folder per agent, each an AgentAdapter implementation.
BentoScanner     Orchestrates adapters, FSEvents watcher, incremental re-scan, debouncing.
BentoLogIngest   Streaming JSONL + zstd reader, per-agent log decoders → UsageEvent.
BentoTokenizer   Tokenizer protocol, o200k/cl100k BPE port, heuristic, calibration, API counters.
BentoMCPProbe    Spawns MCP servers (stdio / HTTP) with consent, calls initialize + tools/list.
BentoHygiene     Normalization, shingling/MinHash near-dup, conflict rules, limit checks.
BentoFixes       FixPlan → diff preview → backup → apply → verify → undo. ONLY writer.
BentoStore       GRDB SQLite: snapshots, usage events, calibration, fix journal, settings.
BentoUI          SwiftUI views + view models (macOS 15, Observation framework, Swift Charts).
BentoApp         @main app target (thin), Sparkle (M5), menu commands.
bentoctx (CLI)      swift-argument-parser executable sharing everything except UI/App.
```

### 3.2 Dependency graph (allowed imports)
```
Core ← Parsing ← Adapters ← Scanner
Core ← Tokenizer
Core ← LogIngest (← Parsing)
Core ← MCPProbe
Core ← Hygiene (← Parsing, Tokenizer)
Core ← Fixes (← Parsing, Store)
Core ← Store
UI   ← Core, Scanner, LogIngest, Tokenizer, MCPProbe, Hygiene, Fixes, Store
CLI  ← same as UI minus UI
App  ← UI
```
A `Package.swift` test (`DependencyGraphTests`) asserts this by parsing the target dependencies.

### 3.3 Third-party dependencies (pinned, minimal)
| Package | Purpose |
|---|---|
| `groue/GRDB.swift` (v7+) | SQLite store, migrations, observation |
| `apple/swift-argument-parser` | CLI |
| `apple/swift-collections` | OrderedDictionary, Deque |
| `LebJe/TOMLKit` *or* `dduan/TOMLDecoder` (choose in T03 ADR) | Codex/Gemini TOML |
| `jpsim/Yams` | Skill/rule YAML frontmatter |
| zstd: vendored `facebook/zstd` C sources as an SPM C target (`CZstd`) | streaming `.jsonl.zst` |
| `sparkle-project/Sparkle` (App only, M5) | updates |
| `swift-markdown` (optional) | heading-aware rule chunking |

The tokenizer is implemented in-house (a BPE merge-table loader). Vocab files are bundled as resources with their licenses (§6.3).

### 3.4 Runtime flow
```
FSEvents ─► Scanner ─► [Adapter.discover(home, folder)] ─► Artifacts
                                   │
                                   ├─► Adapter.resolve(folder) ─► Resolution (ordered, with shadowing)
                                   ├─► Tokenizer.count(...)     ─► BudgetItems
                                   ├─► MCPProbe (consented)     ─► ToolSchemas (cached by config hash)
LogIngest (background, incremental by file offset) ─► UsageEvents ─► Store
Hygiene(Resolution set across agents) ─► Findings
UI/CLI query Store + in-memory snapshot (actor `Workspace`)
Fixes: Finding/User action ─► FixPlan ─► Preview(diff) ─► Backup ─► Apply ─► Rescan ─► Journal
```

### 3.5 Concurrency model
- `actor Workspace` holds the current `Snapshot` (an immutable struct) and publishes changes via `AsyncStream<SnapshotDelta>`.
- Adapters are `Sendable` structs with `async` methods and no shared mutable state.
- LogIngest runs as a detached task group with a bounded concurrency of 4 and is cancellable. Progress is reported via `AsyncStream`.
- UI view models are `@MainActor @Observable`.

---

## 4. Data model

### 4.1 Core Swift types (in `BentoCore`)
```swift
public enum AgentID: String, Sendable, Codable, CaseIterable {
    case claudeCode, codex, gemini, copilot, cursor, windsurf
}

public enum Scope: Int, Sendable, Codable, Comparable {   // lower = higher priority unless adapter overrides
    case managed = 0, projectLocal, project, directory, user, builtIn
}

public enum ArtifactKind: String, Sendable, Codable {
    case settings, rules, skill, mcpServer, subagent, command, hook, plugin, outputStyle, ignoreFile
}

public struct SourceLocation: Sendable, Codable, Hashable {
    public var path: String            // absolute, symlinks NOT resolved
    public var realPath: String        // symlinks resolved
    public var keyPath: [String]?      // e.g. ["mcpServers","github"] or ["mcp_servers","github"]
    public var lineRange: ClosedRange<Int>?
}

public struct Artifact: Sendable, Codable, Identifiable, Hashable {
    public var id: ArtifactID          // stable: sha256(agent|kind|scope|path|keyPath)
    public var agent: AgentID
    public var kind: ArtifactKind
    public var scope: Scope
    public var name: String            // skill name, server name, file name
    public var location: SourceLocation
    public var contentHash: String     // sha256 of normalized bytes
    public var enabled: Bool           // after applying disable flags
    public var loadMode: LoadMode      // how/when it enters context
    public var payload: ArtifactPayload
    public var diagnostics: [Diagnostic]
}

public enum LoadMode: Sendable, Codable, Hashable {
    case always                        // e.g. CLAUDE.md, AGENTS.md
    case frontmatterOnly               // skill: name+description always, body on invoke
    case deferred                      // MCP tool search / lazy tools
    case onInvoke                      // commands, subagent bodies
    case conditional(globs: [String])  // .cursor/rules with globs, *.instructions.md applyTo
    case never                         // disabled
}

public enum ArtifactPayload: Sendable, Codable, Hashable {
    case rules(RulesDoc)
    case skill(SkillDoc)               // frontmatter + body + supporting files list
    case mcpServer(MCPServerConfig)
    case subagent(SubagentDoc)
    case command(CommandDoc)
    case hook(HookConfig)
    case settings(SettingsDoc)         // raw JSON/TOML tree, redacted
    case plugin(PluginManifest)
    case other
}

public struct MCPServerConfig: Sendable, Codable, Hashable {
    public enum Transport: Sendable, Codable, Hashable { case stdio(command: String, args: [String]), http(url: String), sse(url: String) }
    public var transport: Transport
    public var envKeys: [String]       // KEYS ONLY. Values never stored.
    public var disabled: Bool
    public var allowedTools: [String]?
    public var disabledTools: [String]?
}

public struct Resolution: Sendable, Codable {
    public var agent: AgentID
    public var folder: String
    public var ordered: [ResolvedArtifact]     // in load order
    public var shadowed: [ShadowRecord]        // artifact X overridden by Y and why
    public var warnings: [Diagnostic]
}

public struct ResolvedArtifact: Sendable, Codable, Hashable {
    public var artifactID: ArtifactID
    public var effectiveLoadMode: LoadMode
    public var reason: String                  // "project .mcp.json, approved in ~/.claude.json"
}

public enum Confidence: String, Sendable, Codable { case exact, estimated, measured }

public enum BudgetCategory: String, Sendable, Codable, CaseIterable {
    case builtInSystem, builtInTools, rules, skillFrontmatter, skillBody,
         mcpToolsLoaded, mcpToolsDeferred, subagents, commands, hooks, other
}

public struct BudgetItem: Sendable, Codable, Hashable {
    public var artifactID: ArtifactID?         // nil for built-ins
    public var category: BudgetCategory
    public var label: String
    public var tokens: Int
    public var range: ClosedRange<Int>?        // for estimates
    public var confidence: Confidence
    public var method: String                  // "o200k_base", "heuristic chars/3.6 (calibrated k=1.08)", "anthropic count_tokens", "log first-turn delta"
    public var countsTowardPrePrompt: Bool     // false for deferred/onInvoke (shown hatched)
}

public struct Budget: Sendable, Codable {
    public var agent: AgentID; public var folder: String; public var model: String?
    public var items: [BudgetItem]
    public var measuredFirstTurnInput: Int?    // median from logs for this folder
    public var contextWindow: Int?
}

public struct UsageEvent: Sendable, Codable, Hashable {
    public var agent: AgentID
    public var sessionID: String
    public var timestamp: Date
    public var cwd: String?
    public var kind: Kind
    public enum Kind: Sendable, Codable, Hashable {
        case sessionStart(model: String?)
        case tokenUsage(input: Int, cachedInput: Int?, output: Int, turnIndex: Int)
        case skillInvoked(name: String)
        case mcpToolCalled(server: String, tool: String)
        case subagentInvoked(name: String)
        case commandInvoked(name: String)
        case builtinToolCalled(name: String)
    }
}

public struct Finding: Sendable, Codable, Identifiable, Hashable {
    public var id: String
    public enum Kind: String, Sendable, Codable { case nearDuplicate, exactDuplicate, conflict, sizeLimit, unused, brokenImport, shadowed, invalidConfig }
    public var kind: Kind
    public var severity: Severity              // info, warning, error
    public var artifacts: [ArtifactID]
    public var spans: [SourceLocation]
    public var message: String
    public var suggestedFixes: [FixKind]
}
```

### 4.2 SQLite schema (GRDB migrations, `BentoStore`)
```
snapshot(id PK, created_at, home_hash, scanner_version)
artifact(id PK, snapshot_id FK, agent, kind, scope, name, path, real_path, key_path_json,
         content_hash, enabled, load_mode_json, payload_json, diagnostics_json)
repo(id PK, path UNIQUE, display_name, last_seen_at, pinned BOOL)
budget_item(snapshot_id, repo_id, agent, artifact_id NULL, category, label, tokens,
            range_lo, range_hi, confidence, method, counts_pre_prompt)
log_file(path PK, agent, size, mtime, inode, offset_consumed, compressed BOOL, last_error)
usage_event(id PK, agent, session_id, ts, cwd, repo_id NULL, kind, name, server, tool,
            input_tokens, cached_input_tokens, output_tokens, turn_index, model)
  INDEX(agent, kind, name, ts), INDEX(repo_id, ts)
session(agent, session_id PK, started_at, cwd, repo_id, model, first_turn_input)
calibration(agent, model, tokenizer_id, k_factor, n_samples, residual_stddev, updated_at)
mcp_probe(server_config_hash PK, agent, server_name, probed_at, ok, error, tools_json,
          tools_tokens_estimate, protocol_version)
finding(id PK, snapshot_id, kind, severity, artifacts_json, spans_json, message, dismissed BOOL)
fix_journal(id PK, created_at, kind, plan_json, backup_dir, status, applied_at, undone_at, error)
setting(key PK, value_json)            -- incl. api key REFERENCES (Keychain item names), not keys
```
- Retention: usage events are kept for 180 days by default (configurable). A `VACUUM` runs on a schedule.
- The DB lives at `~/Library/Application Support/<Product.supportDirName>/bento.sqlite`. Backups go in `…/Backups/<ISO8601>-<fixID>/`.

---

## 5. Agent adapters

### 5.1 Protocol sketch
```swift
public struct AgentEnvironment: Sendable {
    public var home: URL                       // injected; fixture home in tests
    public var env: [String: String]           // CLAUDE_CONFIG_DIR, CODEX_HOME, GEMINI_*, XDG_*…
    public var fileSystem: any ReadOnlyFileSystem
    public var now: @Sendable () -> Date
}

public protocol ReadOnlyFileSystem: Sendable {
    func contents(at url: URL) throws -> Data
    func list(_ url: URL) throws -> [URL]
    func attributes(_ url: URL) throws -> FileAttributes      // size, mtime, inode, isSymlink
    func exists(_ url: URL) -> Bool
    func resolveSymlinks(_ url: URL) -> URL
}

public struct PathCatalog: Sendable {           // every known path, each with doc provenance
    public struct Entry: Sendable { public var id: String; public var pattern: String; public var scope: Scope; public var kind: ArtifactKind; public var verifiedAt: String?; public var docURL: String? }
    public var entries: [Entry]
}

public struct AgentCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public static let inventory, resolution, budget, usageLogs, mcpProbe, fixes: AgentCapabilities
}

public protocol AgentAdapter: Sendable {
    static var id: AgentID { get }
    var displayName: String { get }
    var capabilities: AgentCapabilities { get }
    var paths: PathCatalog { get }

    /// Is the agent installed / configured at all on this machine?
    func detect(in env: AgentEnvironment) async -> DetectionResult

    /// All artifacts at global scope + those reachable from `folder` (walking up to repo root / home).
    func discover(in env: AgentEnvironment, folder: URL?) async throws -> [Artifact]

    /// Order + merge artifacts exactly as the agent would when launched in `folder`.
    func resolve(_ artifacts: [Artifact], folder: URL, env: AgentEnvironment) -> Resolution

    /// Static built-in overhead (system prompt + built-in tools) per model, as BudgetItems.
    func builtInBudget(model: String?) -> [BudgetItem]

    /// How each artifact contributes to context (frontmatter vs body, deferred tools…).
    func budgetContributions(for resolved: ResolvedArtifact, artifact: Artifact) -> [BudgetContribution]

    /// Log discovery + decoding. Decoders must be streaming and resumable by byte offset.
    func logSources(in env: AgentEnvironment) throws -> [LogSource]
    func makeLogDecoder() -> any LogDecoder

    /// Which fixes this agent supports and how to express them (e.g. disabled key name).
    func fixSupport() -> FixSupport
}

public protocol LogDecoder: Sendable {
    /// Called per JSON line; returns zero or more events. Must tolerate unknown fields/types.
    mutating func decode(line: Data, source: LogSource) -> [UsageEvent]
}
```
A shared `AdapterContractTests` suite runs against every adapter with its fixture home. It checks determinism, read-only behaviour, stable IDs, tolerance of unknown fields, and resolution order.

### 5.2 Per-agent path catalogs. All paths: *(verify against current docs)*

**Claude Code** (`Adapters/ClaudeCode`)
| What | Path(s) | Notes |
|---|---|---|
| Settings | `~/.claude/settings.json`, `<repo>/.claude/settings.json`, `<repo>/.claude/settings.local.json`, managed settings (`/Library/Application Support/ClaudeCode/managed-settings.json`) | precedence: managed > local > project > user *(verify)* |
| MCP | `~/.claude.json` (user and per-project `projects[<path>].mcpServers`), `<repo>/.mcp.json` | project servers may need approval (`enabledMcpjsonServers` / `disabledMcpjsonServers`) *(verify)* |
| Memory/rules | `~/.claude/CLAUDE.md`, `<repo>/CLAUDE.md`, `<repo>/CLAUDE.local.md`, nested `CLAUDE.md` in parents/children, `.claude/rules/**/*.md` | `@path` imports (recursive, max depth) *(verify)* |
| Skills | `~/.claude/skills/*/SKILL.md`, `<repo>/.claude/skills/*/SKILL.md`, plugin skills | frontmatter always loaded, body on invoke |
| Plugins | `~/.claude/plugins/cache/**` (+ marketplace/installed manifests) | plugins may bring skills, agents, commands, hooks, MCP |
| Subagents | `~/.claude/agents/*.md`, `<repo>/.claude/agents/*.md` | name+description in the Task tool description |
| Commands | `~/.claude/commands/**/*.md`, `<repo>/.claude/commands/**/*.md` | |
| Hooks | `hooks` key in settings files | hook *output* may inject context (mark as measured-only) |
| Logs | `~/.claude/projects/<encoded-cwd>/*.jsonl` | `message.usage.input_tokens`, `cache_*_input_tokens`; `tool_use` blocks (`Skill`, `Task`, `mcp__<server>__<tool>`). Responses can be duplicated per streamed chunk: **dedupe by `message.id`/`requestId`** |
| Env overrides | `CLAUDE_CONFIG_DIR` | *(verify)* |

**Codex CLI** (`Adapters/Codex`)
| What | Path(s) | Notes |
|---|---|---|
| Config | `~/.codex/config.toml` (`$CODEX_HOME`), `<repo>/.codex/config.toml`, profiles `[profiles.*]` | project config trust rules *(verify)* |
| MCP | `[mcp_servers.<name>]` tables (command/args/env/url, `enabled`, `enabled_tools`/`disabled_tools`) | *(verify key names)* |
| Rules | `~/.codex/AGENTS.md`, `AGENTS.override.md`, `AGENTS.md` from repo root down to cwd, fallback filenames config, `project_doc_max_bytes` truncation | *(verify)* |
| Skills | `~/.codex/skills`, `<repo>/.agents/skills/*/SKILL.md`, `~/.agents/skills` | *(verify)* |
| Hooks | `hooks.json` (global/project) | *(verify)* |
| Logs | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` and `.jsonl.zst` | `event_msg` with `type: token_count` (`info.total_token_usage`, `last_token_usage`), `session_meta` (cwd, model), function_call items for MCP tools *(verify)* |

**Gemini CLI** (`Adapters/Gemini`)
| What | Path(s) | Notes |
|---|---|---|
| Settings | `~/.gemini/settings.json`, `<repo>/.gemini/settings.json`, system settings (`/Library/Application Support/GeminiCli/settings.json`) | *(verify)* |
| MCP | `mcpServers` in settings; `excludeTools`/`includeTools`; extensions `~/.gemini/extensions/*/gemini-extension.json` | |
| Rules | `~/.gemini/GEMINI.md`, `GEMINI.md` hierarchy (ancestors + subdirs), `context.fileName` override (may be `AGENTS.md`), `@file` imports | *(verify)* |
| Commands | `~/.gemini/commands/**/*.toml`, `<repo>/.gemini/commands/**/*.toml` | |
| Logs | `~/.gemini/tmp/<project-hash>/chats/session-*.jsonl` (older: `.json`) | `usageMetadata`/`tokens` fields; project hash = sha256(cwd) *(verify)* |

**Copilot CLI** (`Adapters/Copilot`)
| What | Path(s) | Notes |
|---|---|---|
| Rules | `<repo>/.github/copilot-instructions.md`, `<repo>/.github/instructions/*.instructions.md` (`applyTo` globs), `AGENTS.md` support, `~/.copilot/copilot-instructions.md` | *(verify)* |
| MCP | `~/.copilot/mcp-config.json`, `<repo>/.github/mcp.json` (or `.vscode/mcp.json`) | built-in GitHub MCP server *(verify)* |
| Agents | `~/.copilot/agents`, `<repo>/.github/agents/*.agent.md` | *(verify)* |
| Logs | `~/.copilot/session-state/<id>/events.jsonl` | tool call + usage events *(verify)* |

**Cursor** (`Adapters/Cursor`: inventory + rules audit only)
- `.cursor/rules/**/*.mdc` (frontmatter `description`, `globs`, `alwaysApply`), legacy `.cursorrules`, `~/.cursor/mcp.json`, `<repo>/.cursor/mcp.json`, `AGENTS.md`. User rules live in Cursor's app DB and are **out of scope** *(verify)*.

**Windsurf** (`Adapters/Windsurf`: inventory + rules audit only)
- `~/.codeium/windsurf/memories/global_rules.md` (**6,000-char limit**), `<repo>/.windsurf/rules/*.md` (**12,000 chars/file**, trigger modes in frontmatter), legacy `.windsurfrules`, `~/.codeium/windsurf/mcp_config.json` *(verify limits & paths)*.

### 5.3 Repo discovery
- Sources: (1) Claude `~/.claude.json` project keys and `~/.claude/projects/*` decoded cwd, (2) Codex `session_meta.cwd`, (3) Gemini project hashes matched against known cwds, (4) Copilot session cwd, (5) folders the user adds manually, (6) an optional shallow scan of `~/Developer`, `~/code`, `~/src` and `~/Projects` (depth ≤ 3, `.git` present). The user can pin or hide repos.

---

## 6. Subsystems

### 6.1 Scanner & FS watcher
- `FSEventStreamCreate` on: every agent home dir, pinned repos (their agent-relevant subpaths only), and log dirs (separate stream, lower priority). Uses `kFSEventStreamCreateFlagFileEvents`, a 300 ms latency and debouncing.
- Incremental: map each changed path to the adapter(s) via `PathCatalog` glob matching, and re-discover only the affected scope. Content-hash caching means unchanged bytes are never re-tokenized.
- Fallback: polling if an FSEvents stream fails. Wrapped behind a `FileWatcher` protocol so tests use a manual trigger.

### 6.2 LogIngest
- `StreamingLineReader`: an `AsyncSequence<Data>` over a `FileHandle` with a 64 KB buffer. It handles partial trailing lines (it doesn't commit the offset past the last newline) and caps lines at 16 MB (oversized lines are skipped with a diagnostic).
- `ZstdLineReader`: streaming decompression (`ZSTD_decompressStream`) feeding the same line splitter. A compressed file is treated as immutable once it's closed, so it's re-read only if its size, mtime or inode changes.
- Resumable: `log_file.offset_consumed` for plain JSONL. Rotation/truncation is detected via inode/size shrink, and the file is then re-read from 0 while deduping on `(session_id, event uid)`.
- Decoders use `JSONSerialization`, or a lightweight key-path scan for speed. They ignore unknown types and record decoder errors per file without failing the run.
- Privacy: decoders extract **only** counts, names, timestamps, cwd and model. Prompt and response text is never stored.
- Performance target: ≥ 150 MB/s on Apple Silicon for plain JSONL, verified by a benchmark test (generated 500 MB corpus, run in `--benchmark` mode only).

### 6.3 Tokenizer
- `protocol TokenCounter: Sendable { var id: String; func count(_ text: String) -> Int }`
- Implementations:
  - `BPETokenizer(o200k_base / cl100k_base)`: a Swift port of tiktoken's byte-level BPE (regex pre-split plus rank merges). Vocab files are bundled (MIT, from openai/tiktoken). This is **exact** for OpenAI models (Codex) when the model→encoding map matches, and **estimated** otherwise.
  - `HeuristicCounter`: chars/k with separate k for prose, code and JSON. A proxy for Claude and Gemini, labelled estimated.
  - `CalibratedCounter(base, k)`: base × k per (agent, model), where k is fitted by least squares from log samples.
  - `AnthropicCountTokens` (`POST /v1/messages/count_tokens`) and `GeminiCountTokens` (`models/{model}:countTokens`): opt-in, with the key stored in **Keychain**. Results are cached by content hash and labelled **exact**.
- Calibration algorithm: for each session in the logs with a known cwd, take the first-turn input tokens (Claude: `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` of the first assistant message; Codex: the first `token_count` `last_token_usage.input_tokens`) and subtract the estimated user first message, if logged (length only). Regress against the predicted pre-prompt from the snapshot of that repo at that time (approximated by the current snapshot when hashes match). Store k, n and the residual. Show the "measured" bar next to the estimated stack.
- Built-in overhead: the per-agent, per-model constants in `Resources/builtins/<agent>.json` start as measured placeholders (`measured on <date>, agent version X`). The rest of the bar is calibrated from the gap between measured first-turn input and the sum of user artifacts in a near-empty fixture repo. The UI always labels them as "estimated (built-in)".

### 6.4 MCP probe
- Consent per server, remembered by config hash. A re-prompt happens if the command, args or env keys change.
- stdio: `Process` with a scrubbed env (only the PATH/HOME and env keys the config declares, with values read from the agent's own config, never logged), cwd = repo, and a 15 s timeout. Sequence: JSON-RPC `initialize` → `notifications/initialized` → `tools/list` (with pagination) → close. stderr is captured to a bounded buffer.
- HTTP/SSE: Streamable HTTP with the same handshake. **OAuth-requiring servers are skipped in v1** (marked "unprobed").
- Token estimate = the tokenized JSON of `{name, description, inputSchema}` per tool, using the agent's serialization approximation. It's labelled estimated unless an API count is enabled.
- Deferred vs loaded: an adapter rule decides it (e.g. Claude's tool-search/deferred MCP tools when the tool count or token threshold is exceeded, or a setting) *(verify)*. Deferred tools show hatched, plus a small always-loaded stub cost.
- Without a probe: show "unknown (not probed)" with a median-per-tool fallback estimate from previously probed servers, labelled estimated with a wide range.

### 6.5 Hygiene
- Normalization: strip markdown syntax, lowercase, collapse whitespace, split into "rule units" (bullets, numbered items, sentences under headings).
- Exact dupes: hash of the normalized unit.
- Near-dupes: 5-gram word shingles → MinHash (128 perms) → LSH bands, then Jaccard ≥ 0.8 → `nearDuplicate`. Block-level: if ≥ 70% of a file's units appear in another file, suggest an `@AGENTS.md` import.
- Conflicts (v1, rule-based, deterministic): a pattern library in `Resources/hygiene/conflicts.yaml` of opposing directive pairs (e.g. "use tabs" vs "use spaces", "npm" vs "pnpm/yarn/bun", "always/never commit", "run tests before" vs "don't run tests", language/framework versions, line-length numbers). Uses modality detection (must/always/never/don't) on the same subject term. Output: a `conflict` finding with both spans. *No LLM in v1.*
- Limits: Windsurf global 6,000 chars and workspace 12,000 chars per file; Codex `project_doc_max_bytes` truncation; Claude import depth; very large always-on rule files (> N tokens, configurable).
- Broken `@imports`, unreadable files, invalid JSON/TOML → `invalidConfig`.
- Unused (joined with usage): skill/MCP tool/subagent with 0 invocations in N days (default 30) and ≥ M sessions in that repo (default 5, so we don't flag new repos).

### 6.6 Fixes (only writer)
- `FixKind`: `disableMCPServer`, `enableMCPServer`, `disableSkill`, `enableSkill`, `consolidateSkillsViaSymlink`, `replaceDuplicateRulesWithImport`, `trashArtifact` (confirmation required, used by consolidation).
- Pipeline: `plan(fix, snapshot) -> FixPlan` (a list of `FileOp`: `.writeFile(path, newBytes, expectedOldHash)`, `.symlink(from,to)`, `.moveToTrash(path)`, `.mkdir`) → `preview(plan) -> [UnifiedDiff]` → user confirms → `apply`:
  1. Re-hash every target and abort if any changed since planning (TOCTOU guard).
  2. Copy each target into the backup dir with a `manifest.json` (original path, hash, mode, symlink target).
  3. Write atomically (temp file in the same dir + `replaceItemAt`), keep file modes, and keep JSON/TOML formatting by doing **minimal text edits** (edit spans, never a full re-serialization). Use a format-preserving editor per format: a JSON span editor and a TOML line editor.
  4. Deletions go through `FileManager.trashItem` only.
  5. Re-scan the affected scope and verify the expected post-state, rolling back automatically on mismatch.
  6. Write the journal entry. `undo(fixID)` restores from the backup, after verifying the current hash still equals the post-apply hash or asking to force.
- Disable semantics per agent *(verify each)*:
  - Claude MCP: project servers via `disabledMcpjsonServers` in `.claude/settings.local.json`; user servers by moving the entry to a Bento-managed `_bentoDisabled` stash in the backup (not left in the agent file).
  - Codex MCP: `enabled = false` in `[mcp_servers.x]`.
  - Gemini: `excludeTools` / remove from `mcpServers` with a stash.
  - Skills: move the skill dir to `<support>/Disabled/<agent>/<scope>/<name>` (reversible), or use an agent-native disable flag if one exists.
- Symlink consolidation: choose a canonical location (`~/.agents/skills/<name>` by default, configurable) and replace identical copies (same content hash tree) with symlinks. **Never consolidate non-identical skills.** The diff view shows them instead.
- `@AGENTS.md` import: in CLAUDE.md/GEMINI.md, replace the duplicated block with `@AGENTS.md` (or a relative path), keeping the non-duplicated, agent-specific lines. This applies only if the target agent supports imports, which is checked from `FixSupport`.
- Global safety: there's a master toggle, "Allow changes" (off by default). The CLI requires `--apply` and refuses without a TTY unless `--yes` is given. Fixes never write inside `.git/`.

### 6.7 UI (SwiftUI, macOS 15)
- `NavigationSplitView`: Sidebar (Overview, Repos list with search, Agents, Findings, Usage, Fix History, Settings) → content → inspector.
- **Overview:** detected agents, total artifacts, top findings, and the biggest budget consumers.
- **Repo detail:** an agent picker (segmented). Tabs:
  - *Budget:* a Swift Charts horizontal stacked bar per agent, with categories coloured, deferred/on-invoke hatched, and a measured marker line. Below it is a table of items with tokens, confidence badge (Exact / Est. / Measured) and method tooltip.
  - *Resolution:* load-order list with scope badges, shadowed items struck through with a reason, and "Reveal in Finder" / "Open in editor".
  - *Usage:* per item, invocations over N days, last used, and tokens/session. Sortable by "cost × unused".
  - *Hygiene:* findings with side-by-side spans.
- **Fix sheet:** list of FileOps, a unified diff viewer (monospaced, coloured), backup location, and an Apply button (disabled unless "Allow changes" is on).
- Settings: repos roots, retention days, unused thresholds, tokenizer/API keys (Keychain), MCP probe consents, canonical skills dir, product name override (dev builds only).
- Accessibility: VoiceOver labels on chart segments, plus keyboard navigation.

### 6.8 CLI (`bentoctx`)
```
bentoctx scan [--home PATH] [--json]
bentoctx inventory [--agent A] [--repo PATH] [--json]
bentoctx resolve --repo PATH --agent A [--json]
bentoctx budget --repo PATH [--agent A] [--probe-mcp NAME...] [--api anthropic|gemini] [--json]
bentoctx usage [--days N] [--repo PATH] [--json]
bentoctx hygiene [--repo PATH] [--json] [--fail-on warning|error]
bentoctx fix <kind> <target> [--dry-run (default)] [--apply] [--yes]
bentoctx undo <fix-id>
bentoctx ingest [--reset]
```
JSON output is a versioned schema (`"schemaVersion": 1`) documented in `Docs/cli-schema.md`. The CLI and app share the same Store (WAL mode, file lock for fixes).

---

## 7. Privacy & security
- Everything is local. No telemetry, analytics or crash upload. Network is used only for opt-in token-count APIs (with a per-request preview of what's sent: artifact text only, never logs) and Sparkle (M5, can be turned off).
- Secrets: MCP `env` values, `headers`, `Authorization` and anything matching `/(key|token|secret|password)/i` are **redacted at parse time** (`«redacted»`) and never written to SQLite, logs or exports. API keys live in the Keychain only.
- Logs: only counts, names, timestamps, cwd and model are persisted. Prompt content is never stored. "Delete all Bento data" in Settings.
- No sandbox, so Hardened Runtime is required. On first run, explain why Full Disk Access is *not* required (home-dir files are readable without it), and detect and explain any TCC denials (e.g. repos in `~/Documents` or `~/Desktop`).
- MCP probe runs third-party code, so it needs explicit consent, a timeout, a scrubbed env and no TTY. The UI states this clearly.
- `os_log` with the privacy `.private` default for paths.

---

## 8. Repo layout
```
/
├─ AGENTS.md                  # short pointer to PLAN.md (for coding agents)
├─ PLAN.md                    # this file
├─ CHANGELOG.md
├─ Package.swift              # all library targets + CLI + tests
├─ Bento.xcodeproj/ or Project.yml (XcodeGen) # App target only, depends on local package
├─ Config/
│  ├─ Product.xcconfig        # PRODUCT_NAME, BUNDLE_ID, CLI_NAME (single rename point)
│  ├─ Signing.xcconfig.example
│  └─ Bento.entitlements    # hardened runtime, no sandbox
├─ Sources/
│  ├─ BentoCore/  BentoParsing/  BentoAdapters/{ClaudeCode,Codex,Gemini,Copilot,Cursor,Windsurf}/
│  ├─ BentoScanner/ BentoLogIngest/ CZstd/ BentoTokenizer/ BentoMCPProbe/
│  ├─ BentoHygiene/ BentoFixes/ BentoStore/ BentoUI/
│  ├─ BentoCLI/             # executable target "bentoctx"
│  └─ BentoApp/             # @main (built by Xcode project)
├─ Resources/
│  ├─ tokenizers/ (o200k_base.tiktoken, cl100k_base.tiktoken, LICENSE)
│  ├─ builtins/<agent>.json   # built-in overhead estimates w/ provenance
│  └─ hygiene/conflicts.yaml
├─ Fixtures/
│  ├─ homes/<scenario>/       # fake $HOME trees (see §9)
│  ├─ repos/<scenario>/       # fake repos
│  ├─ logs/<agent>/           # sanitized real-shape log samples (+ .zst)
│  └─ mcp/fake-server/        # tiny stdio MCP server (Swift script or compiled helper target)
├─ Tests/<Target>Tests/
├─ Docs/
│  ├─ adapters/<agent>.md     # verified paths, doc URLs, dates, quirks
│  ├─ decisions/NNN-*.md      # ADRs
│  └─ cli-schema.md
├─ Scripts/
│  ├─ lint-writes.sh          # forbids write APIs outside Fixes/Store
│  ├─ make-dmg.sh  notarize.sh  bump-version.sh
│  └─ gen-fixture-logs.swift
├─ Casks/agent-bento.rb.template  # Homebrew cask template
└─ .github/workflows/{ci.yml,release.yml}
```

---

## 9. Test strategy
- **Fixture homes:** `Fixtures/homes/` contains complete fake `$HOME` trees. Every adapter reads through the `AgentEnvironment.home` and `ReadOnlyFileSystem` injection, so fixtures need no real home. Scenarios:
  - `empty/`: no agents.
  - `claude-basic/`, `claude-plugins/` (plugin cache with skills/agents/MCP), `claude-precedence/` (managed + user + project + local conflicts).
  - `codex-basic/` (config.toml with mcp_servers, AGENTS.override.md, nested AGENTS.md, sessions .jsonl and .jsonl.zst).
  - `gemini-basic/` (settings, GEMINI.md hierarchy, `@imports`, commands toml, tmp chats).
  - `copilot-basic/`, `cursor-basic/`, `windsurf-limits/` (files just over and under 6,000/12,000 chars).
  - `polyglot/`: all agents and one repo with duplicated and conflicting rules across AGENTS/CLAUDE/GEMINI/.cursor/.github. This is the hygiene golden test.
  - `hostile/`: symlink loops, unreadable files, invalid JSON/TOML, a 20 MB JSONL line, a truncated .zst, non-UTF8 names.
- **Golden files:** `Tests/**/__golden__/*.json` hold the expected Inventory, Resolution, Budget and Findings per scenario. `RECORD_GOLDEN=1 swift test` regenerates them, and a reviewer must inspect the diffs.
- **Contract tests:** `AdapterContractTests` run against every adapter (§5.1).
- **Read-only proof:** run the full scan + ingest + hygiene on a copy of `polyglot/` made read-only, assert no errors due to writes, and assert that tree hashes are unchanged before and after.
- **Fixes tests:** run on a temp copy of fixtures. Check plan → preview snapshot → apply → verify → undo → byte-identical restore, TOCTOU abort, rollback on failure, and format preservation (comments and key order kept in TOML/JSON).
- **LogIngest:** resumability (append lines between runs), rotation, partial last line, zstd streaming, dedupe of Claude duplicated message chunks.
- **Tokenizer:** exactness of the BPE port vs tiktoken reference vectors (`Fixtures/tokenizer/vectors.jsonl`, generated once by a Python script checked into `Scripts/`), and calibration math.
- **MCP probe:** the fake stdio server (`Fixtures/mcp/fake-server`) returns N tools, paginates, sleeps (timeout test), crashes (error test), and prints env (scrub test).
- **UI:** view-model unit tests, plus a small set of `XCUITest` smoke tests (launch with the `-fixtureHome` argument, navigate to the repo, see the stacked bar, open the fix sheet). Snapshot tests are optional.
- **CI:** GitHub Actions on `macos-15`: `swift build`, `swift test --parallel`, `Scripts/lint-writes.sh`, `swift format lint`, and an Xcode app build. A release workflow runs on tags.

---

## 10. Coding conventions
- Swift 6 language mode, `StrictConcurrency` complete, and warnings as errors in CI.
- `swift-format` (Apple) with the repo config: 4-space indent, 120 columns.
- Value types for models. `actor` for shared mutable state. `@Observable` for view models, and no Combine in new code.
- Errors: a typed `enum BentoError: Error` per module. Never `fatalError` in library code.
- Every adapter path comes from `PathCatalog`, so there are no string literals of agent paths elsewhere.
- Public API needs doc comments (`///`). Each module gets a `README.md` with a responsibility paragraph.
- Logging: `Logger(subsystem: Product.bundleID, category: "<module>")`, privacy-aware.
- Tests: Swift Testing (`import Testing`, `@Test`, `#expect`) by default. XCTest only for UI tests.
- No singletons except `Product`. Dependencies are passed in through initializers (environment, fs, clock, store).
- File naming: one primary type per file, `TypeName.swift`. Extensions go in `TypeName+Feature.swift`.

---

## 11. Milestones & tasks
Each task is sized for one agent session (~0.5–2 days of agent work). Tick `[x]` when it's done.

### M0 Skeleton
- [x] **T01 Package & tooling skeleton.** Create `Package.swift` with all targets in §3.1 (empty stubs), `Product.swift`, `Config/Product.xcconfig`, a XcodeGen `Project.yml` for the App target, CI workflow, `swift-format` config, `Scripts/lint-writes.sh`, and `DependencyGraphTests`.
  *AC:* `swift build && swift test` is green on macOS 15. The app launches an empty window titled from `Product.name`. Changing `Product.name` renames the window and CLI help. The lint script fails on a deliberately added `Data.write` in Core (verified by a test script). CI is green.
- [x] **T02 Core models + ReadOnlyFileSystem + fixture harness.** Implement the §4.1 types, `ArtifactID` hashing, `AgentEnvironment`, `LocalReadOnlyFileSystem`, `FixtureHome` test helper, the `empty/` and `polyglot/` skeleton fixtures, and the golden-file helper.
  *AC:* Codable round-trip tests for all models. Stable IDs are covered by a test. The golden helper records and compares.

### M1 Inventory & resolution
- [x] **T03 Parsing module.** JSON (with comments tolerance), TOML (ADR choosing the lib), YAML frontmatter, `.mdc`, markdown rule-unit splitter, `@import` resolver (Claude/Gemini syntax, cycle detection, max depth), secret redaction.
  *AC:* parser tests include malformed inputs from `hostile/`. Redaction tests prove that no secret values survive in `payload_json`.
- [x] **T04 Claude Code adapter.** PathCatalog, discover, resolve (precedence, `.mcp.json` approval, nested CLAUDE.md, rules dir, skills/plugins/agents/commands/hooks), `Docs/adapters/claude-code.md` with verified doc links.
  *AC:* `claude-basic`, `claude-plugins` and `claude-precedence` goldens pass. Contract tests pass. Shadowing reasons are present.
- [x] **T05 Codex + Gemini adapters.** As T04 for Codex (config.toml + project config, mcp_servers, AGENTS.md chain incl. override + byte cap, .agents/skills, hooks.json) and Gemini (settings tiers, GEMINI.md hierarchy + context.fileName, extensions, commands toml).
  *AC:* `codex-basic` and `gemini-basic` goldens and contract tests pass. Docs files are written.
- [x] **T06 Copilot, Cursor, Windsurf adapters + repo discovery.** Copilot full inventory and resolution (`applyTo` → conditional). Cursor/Windsurf inventory + rules only (capabilities exclude budget/usage). Repo discovery from §5.3.
  *AC:* goldens pass. Repo discovery finds all repos referenced by fixture logs/configs, dedupes by real path and ignores missing dirs.
- [x] **T07 Store + Scanner + FSEvents.** GRDB migrations (§4.2), snapshot persistence, `Workspace` actor, `FileWatcher` protocol with an FSEvents implementation, incremental rescan by PathCatalog match, and CLI `scan` / `inventory` / `resolve` with `--json`.
  *AC:* modifying a fixture file in a temp copy triggers a rescan of only that adapter scope (asserted via counters). Cold scan of `polyglot` takes under 500 ms in a test. The read-only proof test passes. CLI JSON matches `Docs/cli-schema.md`.

### M2 Context budget
- [x] **T08 Tokenizer.** BPE port (o200k/cl100k) with reference vectors, HeuristicCounter, the `TokenCounter` protocol, content-hash cache, and the model→counter map per agent.
  *AC:* 100% match on ≥ 1,000 reference vectors. Throughput ≥ 5 MB/s. Heuristic is within ±20% of BPE on the fixture corpus.
- [x] **T09 Budget engine + built-ins.** `budgetContributions` for all budget-capable adapters (skills frontmatter vs body, subagent descriptions, commands, hooks, rules, conditional rules shown separately), `Resources/builtins/*.json` with provenance, and the CLI `budget`.
  *AC:* `polyglot` budget golden for each agent, with every item carrying confidence + method. The sum excludes deferred/onInvoke from pre-prompt.
- [x] **T10 MCP probe.** Fake server fixture, stdio + Streamable HTTP clients, consent store, timeout, env scrub, pagination, cache by config hash, deferred-vs-loaded rules, fallback estimates, and CLI `--probe-mcp`.
  *AC:* tests for success, pagination, timeout (≤ 15 s +1), crash, env scrub (the server can't see unrelated env vars), and cache hit. No probe ever runs without consent (asserted).

### M3 Usage & calibration
- [x] **T11 LogIngest core + decoders.** Streaming line reader, CZstd target + streaming decoder, resumable offsets, rotation handling, and decoders for Claude (dedupe), Codex (token_count, session_meta, tool calls), Gemini and Copilot, writing `usage_event` + `session`. CLI `ingest` / `usage`.
  *AC:* fixture logs yield exact expected event counts (golden). Append-then-reingest adds only the new events. A truncated .zst produces a diagnostic, not a crash. The 500 MB benchmark (opt-in) hits ≥ 150 MB/s plain.
- [x] **T12 Usage join + calibration.** Join usage to artifacts (skill names, `mcp__server__tool`, subagent names, per repo via cwd), "cost × unused" ranking, the `unused` finding, calibration k-factor fitting, and the measured marker in the budget.
  *AC:* in fixtures, an MCP server with 0 calls over 30 days in a repo with ≥ 5 sessions is flagged. Calibration recovers a synthetic k (generated logs with a known k=1.12) within ±0.02. Budget JSON includes `measuredFirstTurnInput`.

### M4 Hygiene, fixes & UI
- [ ] **T13 Hygiene engine.** Normalization, exact/near-dup MinHash-LSH, `conflicts.yaml` pattern library (≥ 15 pairs), limit checks (Windsurf 6k/12k, Codex byte cap), broken imports, and CLI `hygiene --fail-on`.
  *AC:* `polyglot` findings golden (exact count, spans). `windsurf-limits` flags only the over-limit files. False positives on a "clean" fixture = 0.
- [ ] **T14 Fixes module.** FileOp model, format-preserving JSON/TOML editors, diff generator, backup manifest, atomic apply, TOCTOU guard, verify + auto-rollback, Trash, journal, undo. Implements all §6.6 fix kinds for Claude, Codex and Gemini (Copilot: MCP disable only). CLI `fix` / `undo`.
  *AC:* every fix kind round-trips apply→undo byte-identically on temp fixture copies. Comments in TOML/JSONC are preserved. The CLI refuses `--apply` without `--yes` in non-TTY. The lint confirms Fixes is the only writer.
- [ ] **T15 SwiftUI app.** Sidebar/navigation, Overview, Repo detail (Budget chart with confidence badges + hatching + measured marker, Resolution, Usage, Hygiene tabs), Fix sheet with diff preview and "Allow changes" gate, Fix History with Undo, Settings (Keychain API keys, probe consents, thresholds), and first-run onboarding (privacy statement).
  *AC:* XCUITest smoke tests pass against `-fixtureHome polyglot`. All actions are reachable by keyboard. VoiceOver reads chart segments. No writes happen when "Allow changes" is off (asserted via a Fixes spy). Optional Anthropic/Gemini count APIs show a request preview and mark items exact.

### M5 Release
- [ ] **T16 Packaging & release.** Hardened runtime entitlements, Developer ID signing via `Signing.xcconfig`, a universal build, CLI embedded in `App.app/Contents/Helpers/bentoctx` with a "Install CLI" (symlink to `/usr/local/bin` or `~/.local/bin`, with consent) action, `make-dmg.sh` (create-dmg or hdiutil), `notarize.sh` (`notarytool submit --wait` + `stapler staple`), Sparkle appcast (EdDSA, can be turned off), Homebrew cask `agent-bento` (template + tap instructions), `release.yml` on tags, README with privacy section, license, and third-party notices.
  *AC:* a tagged build produces a notarized, stapled DMG that passes `spctl -a -vv` and `xcrun stapler validate`. `brew install --cask` from a local tap installs and launches. The CLI runs from the app bundle. Version and build numbers come from a single source.

---

## 12. Risks & mitigations
| Risk | Mitigation |
|---|---|
| Agent config formats/paths change frequently | PathCatalog + `Docs/adapters` provenance, tolerant decoders, "unknown artifact" bucket, adapter version detection (`claude --version` etc., read-only) |
| Built-in token overhead unknown/varies by version | label estimated; calibrate from logs; show measured marker |
| Claude tokenizer not public | heuristic + calibration + optional count_tokens API (exact) |
| MCP probe runs untrusted code | consent, timeout, scrubbed env, no auto-probe |
| Fix corrupts config | minimal span edits, TOCTOU check, backup, verify, auto-rollback, undo, read-only default |
| Large logs (GBs) | streaming, offsets, background low-QoS, retention |
| TCC prompts for repos in Documents/Desktop | lazy access, clear explanation, graceful skip |

---

## 13. v2 backlog (do not implement in v1)
- Per-repo **profiles**: named loadouts that switch the enabled MCP servers and skills per repo (built on Fixes).
- **Menu bar** extra with budget alerts (threshold per repo/agent, a notification when a change raises the pre-prompt above X).
- **CLI/CI baseline check**: `bentoctx budget --baseline .bento/baseline.json --fail-over 10%` and a GitHub Action that fails PRs that grow the context budget or add rule conflicts.
- **Ruler / rulesync** import/export interop.
- **Team policy**: a checked-in policy file (allowed MCP servers, max budget, required AGENTS.md) and a managed-settings generator.
- LLM-assisted semantic conflict detection (local model, opt-in).
- More agents (OpenCode, Cline, Roo, Kiro, Amp, Junie) via the same protocol.
- Linux build of the CLI.
