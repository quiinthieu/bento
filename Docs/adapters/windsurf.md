# Windsurf Adapter (`windsurf`)

- **Verified against official Windsurf Cascade documentation on:** `2026-10-30`
- **Adapter implementation:** `Sources/BentoAdapters/Windsurf/`
- **Path catalog:** `WindsurfPathCatalog`
- **Scope in v1 (`PLAN.md` §1, §5.2, §11):** Inventory and rules/precedence resolution only (`capabilities = [.inventory, .resolution]`; excludes context token budget and session usage logs).

## Official Documentation Sources

1. **Cascade Memories & Rules (`global_rules.md`, `.windsurf/rules/*.md`, `.windsurfrules`, `AGENTS.md`, system rules):** <https://docs.windsurf.com/windsurf/cascade/memories>
2. **Cascade Model Context Protocol (`~/.codeium/windsurf/mcp_config.json`):** <https://docs.windsurf.com/windsurf/cascade/mcp>
3. **Cascade Workflows (`.windsurf/workflows/*.md`):** <https://docs.windsurf.com/windsurf/cascade/workflows>
4. **Ignore Files (`.codeiumignore`):** <https://docs.windsurf.com/context-awareness/codeiumignore>

## Environment Overrides

| Variable | Effect | Verified Behaviour |
|---|---|---|
| `WINDSURF_CONFIG_DIR` | Overrides `~/.codeium/windsurf` | Optional override relocating Windsurf's user directory (`memories/global_rules.md`, `mcp_config.json`, `global_workflows/`) for hermetic testing. |
| `BENTO_SYSTEM_ROOT` | Bento test-isolation root | Defaults to `/` in production so macOS enterprise rules resolve under `/Library/Application Support/Windsurf/rules`; set to the fixture home root in `FixtureHome` tests. |

## Verified Path Catalog

| Entry ID | Pattern | Scope | Kind | Notes |
|---|---|---|---|---|
| `windsurf.managed.rules` | `/Library/Application Support/Windsurf/rules/*.md` | `managed` | `rules` | Enterprise system-level rules on macOS (12,000-character limit per file). |
| `windsurf.user.globalRules` | `~/.codeium/windsurf/memories/global_rules.md` | `user` | `rules` | Global persistent Cascade rules (`always`, **6,000-character limit**). |
| `windsurf.user.mcp` | `~/.codeium/windsurf/mcp_config.json` | `user` | `mcpServer` | Global MCP server configuration (`mcpServers` with `command`/`args`/`env`, `serverUrl`/`url`, `disabled`, `disabledTools`). |
| `windsurf.user.workflows` | `~/.codeium/windsurf/global_workflows/*.md` | `user` | `command` | Global `/[workflow]` slash-command templates (`onInvoke`). |
| `windsurf.project.rules` | `<repo>/.windsurf/rules/**/*.md` | `project` | `rules` | Modular workspace rules with YAML frontmatter `trigger` (**12,000-character limit** per file). |
| `windsurf.project.legacyRules` | `<repo>/.windsurfrules` | `project` | `rules` | Legacy root `.windsurfrules` instructions (`always`, **12,000-character limit**). |
| `windsurf.project.agentsMd` | `<repo>/AGENTS.md` | `project` | `rules` | Root `AGENTS.md` instructions (`always`, **12,000-character limit**). |
| `windsurf.directory.agentsMd` | `<subdir>/AGENTS.md` | `directory` | `rules` | Directory-scoped `AGENTS.md` (`always` when inside `<subdir>`, `conditional` for descendants). |
| `windsurf.project.workflows` | `<repo>/.windsurf/workflows/*.md` | `project` | `command` | Workspace `/[workflow]` slash-command templates (`onInvoke`); override global workflows of the same name. |
| `windsurf.project.ignore` | `<repo>/.codeiumignore` | `project` | `ignoreFile` | Context indexing and Cascade file-access exclusions. |

## Character Limits & Trigger Modes

1. **Verified Rule Character Limits (`PLAN.md` §5.2 & §6.5):**
   - **Global rules (`~/.codeium/windsurf/memories/global_rules.md`):** `6,000` characters (`WindsurfPathCatalog.globalRuleMaxCharacters`).
   - **Workspace / enterprise rule files (`.windsurf/rules/**/*.md`, `.windsurfrules`, system rules):** `12,000` characters per file (`WindsurfPathCatalog.workspaceRuleMaxCharacters`).
   - Files exceeding their respective character limit set `RulesDoc.wasTruncated = true` and emit a `rules.sizeLimitExceeded` warning `Diagnostic`.

2. **Workspace Rule Frontmatter `trigger` Modes:**
   - `trigger: always_on` (or plain Markdown without `trigger` and without `globs`) → `LoadMode.always`.
   - `trigger: glob` (or omitted `trigger` with non-empty `globs`) → `LoadMode.conditional(globs:)` ( emits `rules.missingGlobs` warning and falls back to `.onInvoke` if `globs` is empty).
   - `trigger: model_decision` (natural-language `description` matching) → `LoadMode.onInvoke`.
   - `trigger: manual` (explicit `@rule-name` invocation) → `LoadMode.onInvoke`.
