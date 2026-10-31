# Claude Code Adapter (`claudeCode`)

- **Verified against official documentation on:** `2026-10-30`
- **Adapter implementation:** `Sources/BentoAdapters/ClaudeCode/`
- **Path catalog:** `ClaudeCodePathCatalog`

## Official Documentation Sources

1. **Settings & Precedence:** <https://code.claude.com/docs/en/settings>
2. **Memory & Rules (`CLAUDE.md`, `.claude/rules/`, `@imports`):** <https://code.claude.com/docs/en/memory>
3. **Model Context Protocol (`.mcp.json`, `~/.claude.json`):** <https://code.claude.com/docs/en/mcp>
4. **Skills (`SKILL.md`):** <https://code.claude.com/docs/en/skills>
5. **Subagents (`agents/*.md`):** <https://code.claude.com/docs/en/sub-agents>
6. **Slash Commands (`commands/**/*.md`):** <https://code.claude.com/docs/en/slash-commands>
7. **Hooks (`hooks` settings & `hooks/hooks.json`):** <https://code.claude.com/docs/en/hooks>
8. **Plugins (`plugins/cache/**`, `.claude-plugin/plugin.json`):** <https://code.claude.com/docs/en/plugins>

## Environment Overrides

| Variable | Effect | Verified Behaviour |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | Overrides `~/.claude` | Relocates user settings, `CLAUDE.md`, `rules/`, `skills/`, `agents/`, `commands/`, `plugins/`, and `projects/` session logs. When `<CLAUDE_CONFIG_DIR>/.claude.json` exists, it is preferred over `~/.claude.json`. |
| `BENTO_SYSTEM_ROOT` | Bento test-isolation root | Defaults to `/` in production so managed paths resolve under `/Library/Application Support/ClaudeCode`. Set to the fixture home root in `FixtureHome` tests so host `/Library` files never leak into hermetic tests. |

## Verified Path Catalog

| Entry ID | Pattern | Scope | Kind | Notes |
|---|---|---|---|---|
| `claude.managed.settings` | `/Library/Application Support/ClaudeCode/managed-settings.json` | `managed` | `settings` | Highest-precedence enterprise policy settings on macOS. |
| `claude.managed.mcp` | `/Library/Application Support/ClaudeCode/managed-mcp.json` | `managed` | `mcpServer` | Enterprise-managed MCP servers (`mcpServers`). |
| `claude.managed.memory` | `/Library/Application Support/ClaudeCode/CLAUDE.md` | `managed` | `rules` | Organization-wide instructions loaded before user/project memory. |
| `claude.user.settings` | `~/.claude/settings.json` | `user` | `settings` | Global user settings, permissions, `enabledPlugins`, and `hooks`. |
| `claude.user.state` | `~/.claude.json` | `user` / `projectLocal` | `mcpServer` | Top-level `mcpServers` (`user` scope) and per-project `projects[<repo>].mcpServers` (`projectLocal` scope) plus project `.mcp.json` approval lists. |
| `claude.user.memory` | `~/.claude/CLAUDE.md` | `user` | `rules` | User-wide memory loaded in every session; supports `@path` imports. |
| `claude.user.rules` | `~/.claude/rules/**/*.md` | `user` | `rules` | User-level modular rule files; optional `paths:` YAML frontmatter globs. |
| `claude.user.skills` | `~/.claude/skills/*/SKILL.md` | `user` | `skill` | Personal skills (`frontmatterOnly`, or `onInvoke` when `disable-model-invocation: true`). |
| `claude.user.agents` | `~/.claude/agents/**/*.md` | `user` | `subagent` | Personal subagents; `name` + `description` advertised to delegation tool. |
| `claude.user.commands` | `~/.claude/commands/**/*.md` | `user` | `command` | Personal slash commands (`onInvoke`); subdirectories map to `dir:name`. |
| `claude.user.plugins.registry` | `~/.claude/plugins/installed_plugins.json` | `user` | `plugin` | Installed plugin registry mapping `name@marketplace` to active cached versions. |
| `claude.user.plugins.manifest` | `~/.claude/plugins/cache/**/.claude-plugin/plugin.json` | `user` | `plugin` | Cached plugin bundles contributing `skills/`, `agents/`, `commands/`, `hooks/hooks.json`, and `.mcp.json`. |
| `claude.user.logs` | `~/.claude/projects/**/*.jsonl` | `user` | `settings` | Per-workspace JSONL session transcripts (usage decoded in `BentoLogIngest`). |
| `claude.project.settings` | `<repo>/.claude/settings.json` | `project` | `settings` | Shared team settings committed to source control. |
| `claude.project.settingsLocal` | `<repo>/.claude/settings.local.json` | `projectLocal` | `settings` | Personal gitignored repo overrides and `.mcp.json` server approvals. |
| `claude.project.mcp` | `<repo>/.mcp.json` | `project` | `mcpServer` | Shared project MCP servers; requires approval in trusted settings/state. |
| `claude.project.memoryRoot` | `<repo>/CLAUDE.md` | `project` | `rules` | Shared project memory at repo root; supports `@path` imports (max depth 5). |
| `claude.project.memoryDotClaude` | `<repo>/.claude/CLAUDE.md` | `project` | `rules` | Alternative shared project memory inside `.claude/`. |
| `claude.project.memoryLocal` | `<repo>/CLAUDE.local.md` | `projectLocal` | `rules` | Personal gitignored repo memory; supports `@path` imports. |
| `claude.project.rules` | `<repo>/.claude/rules/**/*.md` | `project` | `rules` | Modular project rules; YAML frontmatter `paths:` scopes rules to matching globs (`LoadMode.conditional`). |
| `claude.project.skills` | `<repo>/.claude/skills/*/SKILL.md` | `project` | `skill` | Project skills; override user and plugin skills with the same `name`. |
| `claude.project.agents` | `<repo>/.claude/agents/**/*.md` | `project` | `subagent` | Project subagents; override user and plugin subagents with the same `name`. |
| `claude.project.commands` | `<repo>/.claude/commands/**/*.md` | `project` | `command` | Project slash commands; override user and plugin commands with the same `name`. |
| `claude.directory.memory` | `<subdir>/CLAUDE.md` | `directory` | `rules` | Nested `CLAUDE.md` (and `CLAUDE.local.md`). Ancestors of `folder` load at startup (`always`); descendants below `folder` load on demand (`conditional`). |

## Precedence, Approval & Shadowing Semantics

1. **Settings precedence (highest → lowest):**
   `managed` (`managed-settings.json`) > `projectLocal` (`.claude/settings.local.json`) > `project` (`.claude/settings.json`) > `user` (`~/.claude/settings.json`).
   Settings files merge across tiers in base-to-override order (`user` → `project` → `projectLocal` → `managed`), with higher tiers overriding conflicting scalar keys.

2. **Exclusive-by-name artifacts (`mcpServer`, `skill`, `subagent`, `command`):**
   - **MCP servers:** `managed` (`managed-mcp.json`) > `projectLocal` (`~/.claude.json` `projects[<repo>].mcpServers`) > `project` (`<repo>/.mcp.json`) > `user` (`~/.claude.json` `mcpServers`) > `plugin` (`<plugin>/.mcp.json`).
   - **Skills, subagents, commands:** `managed` > `project` > `user` > `plugin`.
   - Overridden lower-precedence definitions are excluded from `Resolution.ordered` and recorded in `Resolution.shadowed` with explicit `ShadowRecord.reason` text.

3. **`.mcp.json` trust & approval rules:**
   - Shared `<repo>/.mcp.json` servers require approval before becoming active.
   - `disabledMcpjsonServers` in any active settings tier or `~/.claude.json` `projects[<repo>]` disables matching `.mcp.json` servers (`effectiveLoadMode = .never`).
   - Enterprise `deniedMcpServers` in `managed-settings.json` blocks matching MCP servers across all non-managed scopes (`effectiveLoadMode = .never`).
   - Approval must come from a **trusted** tier (`managed-settings.json`, `<repo>/.claude/settings.local.json`, `~/.claude/settings.json`, or `~/.claude.json` `projects[<repo>]`) via `enabledMcpjsonServers` or `enableAllProjectMcpServers: true`.
   - Shared `<repo>/.claude/settings.json` **cannot** self-approve `.mcp.json` servers via `enableAllProjectMcpServers` or `enabledMcpjsonServers`.
   - Unapproved `.mcp.json` servers resolve to `effectiveLoadMode = .never` and emit an `mcp.unapproved` warning in `Resolution.warnings`.

4. **Memory & rules concatenation:**
   - All applicable memory and rules files concatenate rather than shadowing one another:
     managed `CLAUDE.md` → user `~/.claude/CLAUDE.md` → user `~/.claude/rules/**/*.md` → project `CLAUDE.md` / `.claude/CLAUDE.md` → `CLAUDE.local.md` → `.claude/rules/**/*.md` → nested ancestor `CLAUDE.md` down to `folder`, followed by conditional child `CLAUDE.md` files under `folder`.
   - `@path` imports are resolved recursively up to 5 hops via `ImportResolver(syntax: .claudeCode, maxDepth: 5)`. Imported files that are not already standalone Claude rule artifacts are included in inventory and resolution right after their importer.

5. **Hooks:**
   - Parsed from the 3-level `hooks.<Event>[i].{matcher, hooks: [{type, command, timeout}]}` schema in settings files and plugin `hooks/hooks.json`.
   - Active hooks across tiers run on lifecycle events (`LoadMode.onInvoke`), unless `disableAllHooks: true` is set by the highest-precedence settings tier defining that key (`effectiveLoadMode = .never`).

6. **MCP Tool Search & Deferred Loading (`ENABLE_TOOL_SEARCH`):**
   - Verified against `https://code.claude.com/docs/en/mcp` (`2026-10-31`): Claude Code's MCP Tool Search (`ENABLE_TOOL_SEARCH` in shell env or `settings.json` `"env"`, plus `enableToolSearch`) supports `true` (always defer MCP tool definitions behind a lightweight tool-search stub), `false` (force upfront `mcpToolsLoaded` loading), `auto` (default **10%** of the model's context window), and `auto:N` (custom `N%` context-window threshold).
   - Individual MCP entries with explicit `deferLoading: true` / `defer_loading: true` / `loadMode: "deferred"` defer unconditionally unless `ENABLE_TOOL_SEARCH=false`; otherwise `BudgetEngine` triggers auto-deferral once aggregate non-deferred MCP tool tokens reach the configured context-window threshold.
