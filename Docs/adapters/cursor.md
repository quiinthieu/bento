# Cursor Adapter (`cursor`)

- **Verified against official Cursor documentation on:** `2026-10-30`
- **Adapter implementation:** `Sources/BentoAdapters/Cursor/`
- **Path catalog:** `CursorPathCatalog`
- **Scope in v1 (`PLAN.md` §1, §5.2, §11):** Inventory and rules/precedence resolution only (`capabilities = [.inventory, .resolution]`; excludes context token budget and session usage logs).

## Official Documentation Sources

1. **Rules for AI (`.cursor/rules/*.mdc`, `AGENTS.md`, legacy `.cursorrules`):** <https://cursor.com/docs/context/rules>
2. **Model Context Protocol (`~/.cursor/mcp.json`, `<repo>/.cursor/mcp.json`):** <https://cursor.com/docs/context/mcp>
3. **Ignore Files (`.cursorignore`, `.cursorindexingignore`):** <https://cursor.com/docs/context/ignore-files>
4. **Subagents & Skills (`.cursor/agents`, `.cursor/skills`):** <https://cursor.com/docs/context/subagents>

## Environment Overrides & Out-of-Scope Storage

| Item | Behaviour |
|---|---|
| `CURSOR_CONFIG_DIR` | Optional environment override relocating `~/.cursor` for hermetic testing. |
| Cursor global User Rules | Stored in Cursor's internal application SQLite database (`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`) and synced with user accounts; **out of scope** in v1 (`PLAN.md` §5.2). |

## Verified Path Catalog

| Entry ID | Pattern | Scope | Kind | Notes |
|---|---|---|---|---|
| `cursor.user.mcp` | `~/.cursor/mcp.json` | `user` | `mcpServer` | Global MCP server configuration (`mcpServers` with `command`/`args`/`env` or `url`/`headers`, `disabled`). |
| `cursor.user.skills` | `~/.cursor/skills/*/SKILL.md` | `user` | `skill` | Personal Cursor skills (`frontmatterOnly`). |
| `cursor.user.agents` | `~/.cursor/agents/*.md` | `user` | `subagent` | Personal Cursor subagents (`frontmatterOnly`). |
| `cursor.project.rules` | `<repo>/.cursor/rules/**/*.mdc` | `project` | `rules` | Modular project rules (`.mdc` and `.md` inside `.cursor/rules/`) parsed via `MDCParser` (`alwaysApply`, `globs`, `description`). |
| `cursor.directory.rules` | `<subdir>/.cursor/rules/**/*.mdc` | `directory` | `rules` | Nested package `.cursor/rules/` directories in monorepos. |
| `cursor.project.legacyRules` | `<repo>/.cursorrules` | `project` | `rules` | Legacy root `.cursorrules` instructions (`always`). |
| `cursor.project.agentsMd` | `<repo>/AGENTS.md` | `project` | `rules` | Root `AGENTS.md` plain Markdown instructions (`always`). |
| `cursor.directory.agentsMd` | `<subdir>/AGENTS.md` | `directory` | `rules` | Nested `AGENTS.md` instructions (`always` on ancestor path to `folder`, `conditional` for descendants). |
| `cursor.project.mcp` | `<repo>/.cursor/mcp.json` | `project` | `mcpServer` | Workspace MCP server definitions; override `~/.cursor/mcp.json` entries with the same server name. |
| `cursor.project.skills` | `<repo>/.cursor/skills/*/SKILL.md` | `project` | `skill` | Workspace Cursor skills; override user skills of the same name. |
| `cursor.project.agents` | `<repo>/.cursor/agents/*.md` | `project` | `subagent` | Workspace Cursor subagents; override user subagents of the same name. |
| `cursor.project.ignore` | `<repo>/.cursorignore` | `project` | `ignoreFile` | Blocks Cursor Agent, Tab, and `@` context access to matching paths. |
| `cursor.project.indexingIgnore` | `<repo>/.cursorindexingignore` | `project` | `ignoreFile` | Excludes matching paths from background codebase indexing. |

## Precedence & Rule Activation Semantics

1. **`.mdc` Frontmatter Activation (`MDCParser`):**
   - `alwaysApply: true` → `LoadMode.always`.
   - `alwaysApply` false/omitted with non-empty `globs` (array or comma-separated string) → `LoadMode.conditional(globs:)`.
   - `alwaysApply` false/omitted and empty `globs` → `LoadMode.onInvoke` (covers both *Apply Intelligently* when `description` is set and *Manual* `@rule-name` invocation).

2. **Rule Ordering:**
   - Rules concatenate without shadowing across files: ancestor `AGENTS.md` → `<repo>/AGENTS.md` → `<repo>/.cursorrules` → `<repo>/.cursor/rules/**` → nested ancestor `<subdir>/AGENTS.md` and `<subdir>/.cursor/rules/**` down to `folder` → descendant rules (`conditional`).

3. **MCP, Skills & Subagents:**
   - Project definitions (`<repo>/.cursor/...`) override user definitions (`~/.cursor/...`) on matching names and record `ShadowRecord` entries in `Resolution.shadowed`.
