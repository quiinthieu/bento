# OpenAI Codex CLI Adapter (`codex`)

- **Verified against official documentation & CLI (`codex-cli 0.165.0`) on:** `2026-10-30`
- **Adapter implementation:** `Sources/BentoAdapters/Codex/`
- **Path catalog:** `CodexPathCatalog`

## Official Documentation Sources

1. **Basic Configuration (`config.toml`, `$CODEX_HOME`):** <https://developers.openai.com/codex/config-basic>
2. **Advanced Configuration (profiles, project trust, requirements):** <https://developers.openai.com/codex/config-advanced>
3. **Custom Instructions (`AGENTS.md`, `AGENTS.override.md`, `project_doc_max_bytes`):** <https://developers.openai.com/codex/guides/agents-md>
4. **Model Context Protocol (`[mcp_servers.<name>]`):** <https://developers.openai.com/codex/mcp>
5. **Agent Skills (`.agents/skills`, `.codex/skills`):** <https://developers.openai.com/codex/skills>
6. **Hooks & Governance (`hooks.json`, `[hooks]`, `/etc/codex/`):** <https://developers.openai.com/codex/security>

## Environment Overrides

| Variable | Effect | Verified Behaviour |
|---|---|---|
| `CODEX_HOME` | Overrides `~/.codex` | Relocates user `config.toml`, `AGENTS.md`, `AGENTS.override.md`, `skills/`, `hooks.json`, and `sessions/` rollout transcripts. Does not relocate `~/.agents/skills`. |
| `CODEX_PROFILE` | Overrides active `profile` | Selects `[profiles.<name>]` from `config.toml` when set, overriding top-level `profile = "..."`. |
| `BENTO_SYSTEM_ROOT` | Bento test-isolation root | Defaults to `/` in production so system paths resolve under `/etc/codex`. Set to the fixture home root in `FixtureHome` tests so host `/etc/codex` files never leak into hermetic tests. |

## Verified Path Catalog

| Entry ID | Pattern | Scope | Kind | Notes |
|---|---|---|---|---|
| `codex.managed.config` | `/etc/codex/config.toml` | `managed` | `settings` | System-wide admin configuration overrides. |
| `codex.managed.requirements` | `/etc/codex/requirements.toml` | `managed` | `settings` | Enterprise governance constraints (e.g. `allow_managed_hooks_only`). |
| `codex.managed.hooks` | `/etc/codex/hooks.json` | `managed` | `hook` | System-managed lifecycle hooks (`SessionStart`, `PreToolUse`, `PostToolUse`, `Stop`). |
| `codex.user.config` | `~/.codex/config.toml` | `user` | `settings` | Global user settings, `[profiles.*]`, `[projects."<path>"].trust_level`, `[mcp_servers.*]`, and `[hooks]`. |
| `codex.user.rulesOverride` | `~/.codex/AGENTS.override.md` | `user` | `rules` | Escape-hatch global instructions; when non-empty, replaces `~/.codex/AGENTS.md`. |
| `codex.user.rules` | `~/.codex/AGENTS.md` | `user` | `rules` | Global user instructions loaded before repository instructions. |
| `codex.user.agentsSkills` | `~/.agents/skills/*/SKILL.md` | `user` | `skill` | Cross-agent personal skills (`frontmatterOnly`); preferred over `~/.codex/skills` on name collision. |
| `codex.user.codexSkills` | `~/.codex/skills/*/SKILL.md` | `user` | `skill` | Codex-specific personal skills (`frontmatterOnly`). |
| `codex.builtin.systemSkills` | `~/.codex/skills/.system/*/SKILL.md` | `builtIn` | `skill` | Bundled Codex system skills (`skill-creator`, `skill-installer`, etc.). |
| `codex.user.hooks` | `~/.codex/hooks.json` | `user` | `hook` | Standalone user lifecycle hook configuration. |
| `codex.user.logs` | `~/.codex/sessions/**/*.jsonl` | `user` | `settings` | Rollout session logs (`rollout-*.jsonl` and `.jsonl.zst` under `sessions/YYYY/MM/DD/`). |
| `codex.project.config` | `<repo>/.codex/config.toml` | `project` | `settings` | Project-scoped TOML overrides and `[mcp_servers.*]`; skipped when project `trust_level = "untrusted"`. |
| `codex.directory.config` | `<subdir>/.codex/config.toml` | `directory` | `settings` | Nested directory `.codex/config.toml` overrides along the ancestor chain from repo root to `folder`. |
| `codex.project.rulesOverride` | `<repo>/AGENTS.override.md` | `project` | `rules` | Repository-root override instructions; replaces `<repo>/AGENTS.md` and fallback filenames in `<repo>`. |
| `codex.project.rules` | `<repo>/AGENTS.md` | `project` | `rules` | Repository-root instructions (plus `project_doc_fallback_filenames` configured in `config.toml`). |
| `codex.directory.rules` | `<subdir>/AGENTS.md` | `directory` | `rules` | Nested `AGENTS.override.md`, `AGENTS.md`, or fallback files from repo root down to `folder` (and conditional descendants). |
| `codex.project.agentsSkills` | `<repo>/.agents/skills/*/SKILL.md` | `project` | `skill` | Repository skills in standard `.agents/skills` directory (plus nested `<subdir>/.agents/skills`). |
| `codex.project.codexSkills` | `<repo>/.codex/skills/*/SKILL.md` | `project` | `skill` | Repository skills in `.codex/skills` directory. |
| `codex.project.hooks` | `<repo>/.codex/hooks.json` | `project` | `hook` | Project lifecycle hooks; skipped when project is untrusted or `allow_managed_hooks_only = true`. |

## Precedence, Trust, Byte Cap & Shadowing Semantics

1. **Settings, Profiles & Project Trust:**
   - Settings merge from base to override: `user` (`~/.codex/config.toml` + active `[profiles.<name>]`) → `project` (`<repo>/.codex/config.toml`) → `directory` (`<subdir>/.codex/config.toml`) → `managed` (`/etc/codex/config.toml`, `/etc/codex/requirements.toml`).
   - Project trust is read from `projects[<path>].trust_level` in `~/.codex/config.toml` (matching the repo root or an ancestor). When `trust_level == "untrusted"`, project/directory `.codex/config.toml`, project `[mcp_servers.*]`, and project `.codex/hooks.json` resolve to `effectiveLoadMode = .never` and emit a `codex.projectUntrusted` warning.

2. **Instruction Chain (`AGENTS.override.md`, `AGENTS.md`, Fallbacks & `project_doc_max_bytes`):**
   - Within any single directory (`$CODEX_HOME` or each directory from repo root down to `folder`), Codex checks `AGENTS.override.md` first, then `AGENTS.md`, then each entry in `project_doc_fallback_filenames` in order.
   - All existing candidate files are discovered into inventory. During resolution, the first non-empty file in a directory wins and shadows any lower-priority files in that **same directory** (recorded in `Resolution.shadowed`).
   - Across directories, winning files concatenate in order: `$CODEX_HOME` → `<repo>` → intermediate ancestors → `folder`. Descendant directories strictly below `folder` resolve as `LoadMode.conditional(globs: ["<relDir>/**"])`.
   - `project_doc_max_bytes` defaults to `32768` (32 KiB) unless overridden in active `config.toml`. When the cumulative UTF-8 byte count across the active instruction chain exceeds `project_doc_max_bytes`, affected documents set `RulesDoc.wasTruncated = true` and emit a `rules.truncated` warning diagnostic. Files reached after the byte budget is completely exhausted resolve to `effectiveLoadMode = .never`.
   - Codex does **not** expand `@path` imports in `AGENTS.md` (`FixSupport.supportsAtImports = false`).

3. **MCP Servers (`[mcp_servers.<name>]`):**
   - Supports stdio (`command`, `args`, `env`, `env_vars`) and Streamable HTTP (`url`, `bearer_token_env_var`, `http_headers`). Only variable keys (`envKeys`) are retained; all secret values and headers are redacted at parse time.
   - `enabled = false` marks `MCPServerConfig.disabled = true` (`effectiveLoadMode = .never`). Tool filters map `enabled_tools` → `allowedTools` and `disabled_tools` → `disabledTools`.
   - Duplicate server names resolve by scope: `managed` > `directory` > `project` (when trusted) > `user`, recording overridden entries in `Resolution.shadowed`.

4. **Skills & Hooks:**
   - Duplicate skill names resolve by scope: `directory` > `project` (`.agents/skills` > `.codex/skills`) > `user` (`~/.agents/skills` > `~/.codex/skills`) > `builtIn` (`~/.codex/skills/.system`), plus `[[skills.config]]` `enabled = false` overrides.
   - Hooks are extracted from standalone `hooks.json` files as well as `[hooks]` tables and `notify` commands in `config.toml`. When `allow_managed_hooks_only = true` is set in managed config/requirements, non-managed hooks resolve to `effectiveLoadMode = .never`.

5. **Rollout Session Log Schema (`CodexLogDecoder`, verified `2026-10-31`):**
   - Path: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` and `.jsonl.zst` (relocated under `$CODEX_HOME/sessions/`).
   - Records are `{ timestamp, type, payload }` envelopes:
     - `session_meta`: `payload.id`, `payload.cwd`, `payload.model`.
     - `turn_context`: per-turn `payload.cwd` and `payload.model` updates.
     - `event_msg` with `payload.type == "token_count"`: extracts `payload.info.last_token_usage` (`input_tokens`, `cached_input_tokens`, `output_tokens`) and suppresses duplicate consecutive emissions where `payload.info.total_token_usage` is unchanged.
     - `response_item`: `function_call` / `custom_tool_call` (deduped by `call_id`, classifying `mcp__<server>__<tool>`, `use_skill`, `spawn_agent`, and built-in tools) and `mcp_tool_call` (`payload.server`, `payload.tool`). Prompt, output, and reasoning text are never stored.
