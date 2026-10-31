# Google Gemini CLI Adapter (`gemini`)

- **Verified against official documentation & CLI (`@google/gemini-cli 0.41.2`) on:** `2026-10-30`
- **Adapter implementation:** `Sources/BentoAdapters/Gemini/`
- **Path catalog:** `GeminiPathCatalog`

## Official Documentation Sources

1. **Configuration Layers & System Overrides:** <https://geminicli.com/docs/reference/configuration>
2. **Settings Reference (`settings.json`):** <https://geminicli.com/docs/cli/settings>
3. **Context Files (`GEMINI.md`, `context.fileName`, `@imports`):** <https://geminicli.com/docs/cli/gemini-md>
4. **MCP Servers (`mcpServers`, `mcp.allowed`, `mcp.excluded`):** <https://geminicli.com/docs/tools/mcp-server>
5. **Agent Skills (`.gemini/skills`, `.agents/skills`):** <https://geminicli.com/docs/cli/skills>
6. **Custom Commands (`commands/**/*.toml`):** <https://geminicli.com/docs/cli/custom-commands>
7. **Subagents (`agents/**/*.md`):** <https://geminicli.com/docs/core/subagents>
8. **Extensions (`extensions/*/gemini-extension.json`):** <https://geminicli.com/docs/extensions/reference>
9. **Hooks (`hooks` in `settings.json` & extension `hooks/hooks.json`):** <https://geminicli.com/docs/hooks/reference>
10. **Ignore Files (`.geminiignore`):** <https://geminicli.com/docs/cli/gemini-ignore>

## Environment Overrides

| Variable | Effect | Verified Behaviour |
|---|---|---|
| `GEMINI_CLI_HOME` | Overrides `~/.gemini` | Verified in `@google/gemini-cli` `bundle/gemini.js`: defaults to `~/.gemini`. If `GEMINI_CLI_HOME` points to a directory containing `.gemini/`, Bento uses `<GEMINI_CLI_HOME>/.gemini`; otherwise `<GEMINI_CLI_HOME>` directly. |
| `GEMINI_CLI_SYSTEM_SETTINGS_PATH` | Overrides system override `settings.json` | Relocates `/Library/Application Support/GeminiCli/settings.json` (`Scope.managed`). |
| `GEMINI_CLI_SYSTEM_DEFAULTS_PATH` | Overrides `system-defaults.json` | Relocates `/Library/Application Support/GeminiCli/system-defaults.json` (`Scope.builtIn`). |
| `BENTO_SYSTEM_ROOT` | Bento test-isolation root | Defaults to `/` in production so macOS system settings resolve under `/Library/Application Support/GeminiCli`. Set to the fixture home root in `FixtureHome` tests. |

## Verified Path Catalog

| Entry ID | Pattern | Scope | Kind | Notes |
|---|---|---|---|---|
| `gemini.managed.settings` | `/Library/Application Support/GeminiCli/settings.json` | `managed` | `settings` | System override settings (`SettingScope.System`); highest precedence, overrides workspace and user settings. |
| `gemini.systemDefaults.settings` | `/Library/Application Support/GeminiCli/system-defaults.json` | `builtIn` | `settings` | System defaults (`SettingScope.SystemDefaults`); lowest precedence baseline overridden by user/workspace/system settings. |
| `gemini.user.settings` | `~/.gemini/settings.json` | `user` | `settings` | Global user settings, `context.fileName`, `mcpServers`, `mcp`, `hooks`, and `agents.overrides`. |
| `gemini.user.memory` | `~/.gemini/GEMINI.md` | `user` | `rules` | Global instructional memory (uses effective `context.fileName`); supports `@file.md` imports. |
| `gemini.user.agentsSkills` | `~/.agents/skills/*/SKILL.md` | `user` | `skill` | Cross-agent personal skills (`frontmatterOnly`); overrides `~/.gemini/skills` within user tier. |
| `gemini.user.geminiSkills` | `~/.gemini/skills/*/SKILL.md` | `user` | `skill` | Gemini personal skills (`frontmatterOnly`). |
| `gemini.user.agents` | `~/.gemini/agents/**/*.md` | `user` | `subagent` | Personal Markdown subagents with YAML frontmatter (`name`, `description`, `model`, `tools`). |
| `gemini.user.commands` | `~/.gemini/commands/**/*.toml` | `user` | `command` | Personal TOML slash commands (`prompt`, `description`); subdirectories namespace with `:` (e.g. `git:commit`). |
| `gemini.user.extensions` | `~/.gemini/extensions/*/gemini-extension.json` | `user` | `plugin` | Installed extension manifests bundling `mcpServers`, context file, `skills/`, `agents/`, `commands/`, and `hooks/hooks.json`. |
| `gemini.user.logs` | `~/.gemini/tmp/*/chats/session-*.json` | `user` | `settings` | Per-project chat transcripts (`session-*.json`, `session-*.jsonl`, and `.zst` under `tmp/<project-hash>/chats/`). |
| `gemini.project.settings` | `<repo>/.gemini/settings.json` | `project` | `settings` | Workspace settings overriding user and system-default settings. |
| `gemini.project.memory` | `<repo>/GEMINI.md` | `project` | `rules` | Workspace context file(s) matching `context.fileName` (string or array, default `["GEMINI.md"]`); supports `@file.md` imports. |
| `gemini.directory.memory` | `<subdir>/GEMINI.md` | `directory` | `rules` | Hierarchical context files in ancestors up to repo root (`always`) and JIT descendants below `folder` (`conditional`). |
| `gemini.project.ignore` | `<repo>/.geminiignore` | `project` | `ignoreFile` | Project file-exclusion patterns for `@` references and file discovery tools. |
| `gemini.project.agentsSkills` | `<repo>/.agents/skills/*/SKILL.md` | `project` | `skill` | Workspace `.agents/skills` alias; overrides `<repo>/.gemini/skills` within workspace tier. |
| `gemini.project.geminiSkills` | `<repo>/.gemini/skills/*/SKILL.md` | `project` | `skill` | Workspace `.gemini/skills` definitions. |
| `gemini.project.agents` | `<repo>/.gemini/agents/**/*.md` | `project` | `subagent` | Workspace subagent definitions; override user and extension subagents of the same name. |
| `gemini.project.commands` | `<repo>/.gemini/commands/**/*.toml` | `project` | `command` | Workspace TOML slash commands; override user and extension commands of the same name. |

## Precedence, Merging & Extension Semantics

1. **Settings Precedence (verified in `@google/gemini-cli` `mergeSettings`):**
   - Highest → lowest: `managed` (`/Library/Application Support/GeminiCli/settings.json`) > `project` (`<repo>/.gemini/settings.json`) > `user` (`~/.gemini/settings.json`) > `builtIn` (`/Library/Application Support/GeminiCli/system-defaults.json`).
   - Settings resolve in base-to-override order (`builtIn` → `user` → `project` → `managed`).

2. **Context Hierarchy (`GEMINI.md`, `context.fileName`, `@imports`):**
   - `context.fileName` in the highest-precedence settings tier defining it accepts either a single filename string or an array of filenames (e.g. `["AGENTS.md", "GEMINI.md"]`), defaulting to `["GEMINI.md"]`.
   - Context files concatenate without shadowing across tiers: user `~/.gemini/<fileName>` → repo root `<repo>/<fileName>` → intermediate ancestors down to `folder` → enabled extension context files (`contextFileName` or `GEMINI.md`), followed by JIT descendant context files below `folder` (`LoadMode.conditional`).
   - `@path` imports are expanded recursively up to 5 hops via `ImportResolver(syntax: .gemini, maxDepth: 5)`. Imported Markdown files not already present as standalone rule artifacts are added immediately after their importer.

3. **MCP Servers (`mcpServers`, `mcp.allowed`, `mcp.excluded`):**
   - Supports stdio (`command`, `args`, `env`, `cwd`), SSE (`url`), and Streamable HTTP (`httpUrl`). `includeTools` maps to `allowedTools`; `excludeTools` maps to `disabledTools`. Secret `env` values and `headers` are redacted at parse time.
   - Duplicate server names resolve by tier: `managed` > `project` > `user` > `builtIn` > `extension` (`settings.json` always overrides extension `mcpServers`), recording shadowed definitions in `Resolution.shadowed`.
   - Servers listed in active `mcp.excluded` (or absent from non-empty `mcp.allowed`) resolve to `effectiveLoadMode = .never`.

4. **Skills, Subagents, Commands & Hooks:**
   - **Skills:** `project` (`.agents/skills` > `.gemini/skills`) > `user` (`~/.agents/skills` > `~/.gemini/skills`) > `extension` (`extensions/*/skills`).
   - **Subagents & Commands:** `project` > `user` > `extension`. TOML commands derive their slash-command name from their relative path under `commands/` with `/` mapped to `:`.
   - **Extensions:** Loaded from `~/.gemini/extensions/*/gemini-extension.json`, respecting `~/.gemini/extensions/extension-enablement.json` and `extensions.disabled` settings.
   - **Hooks:** Extracted from `settings.json` `hooks.<Event>` arrays and extension `hooks/hooks.json`. Gemini CLI hook `timeout` values are configured in milliseconds (default `60000`) and normalized to `HookConfig.timeoutSeconds`.

5. **Chat Transcript Log Schema (`GeminiLogDecoder`, verified `2026-10-31`):**
   - Path: `~/.gemini/tmp/<project-hash>/chats/session-*.jsonl` (modern append-only JSONL), legacy `session-*.json` (`messages[]`), and `.zst` variants. `<project-hash>` resolves to workspace `inferredCwd` via `.project_root` or SHA-256 directory matching.
   - Supports both modern records (`session_metadata`, `gemini`, `message_update` keyed by message `id`) and legacy monolithic JSON documents (`{ sessionId, projectHash, startTime, messages: [...] }`).
   - Extracts token counts from either `tokens` (`input`, `cached`, `output`) or `usageMetadata` (`promptTokenCount`, `cachedContentTokenCount`, `candidatesTokenCount`), and classifies `toolCalls` (deduped by `id`) across `activate_skill`, `delegate_to_agent`, `mcp__<server>__<tool>` / `serverName`, and built-in tools without storing message text.
