# GitHub Copilot CLI Adapter (`copilot`)

- **Verified against official GitHub Copilot CLI documentation on:** `2026-10-30`
- **Adapter implementation:** `Sources/BentoAdapters/Copilot/`
- **Path catalog:** `CopilotPathCatalog`

## Official Documentation Sources

1. **Using GitHub Copilot CLI:** <https://docs.github.com/en/copilot/how-tos/using-github-copilot-cli>
2. **Adding Repository Custom Instructions (`copilot-instructions.md`, `.instructions.md`, `AGENTS.md`):** <https://docs.github.com/en/copilot/customizing-copilot/adding-repository-custom-instructions-for-github-copilot>
3. **Extending GitHub Copilot with MCP (`mcp-config.json`, `.github/mcp.json`, `.vscode/mcp.json`):** <https://docs.github.com/en/copilot/customizing-copilot/extending-copilot-chat-with-mcp>
4. **Custom Agents (`.github/agents/*.agent.md`, `~/.copilot/agents`):** <https://docs.github.com/en/copilot/customizing-copilot/creating-custom-agents>
5. **Agent Skills (`.github/skills/*/SKILL.md`, `~/.copilot/skills/*/SKILL.md`):** <https://docs.github.com/en/copilot/customizing-copilot/using-agent-skills>
6. **Hooks (`.github/hooks/*.json`, `~/.copilot/hooks/*.json`):** <https://docs.github.com/en/copilot/customizing-copilot/using-hooks-with-copilot-cli>

## Environment Overrides

| Variable | Effect | Verified Behaviour |
|---|---|---|
| `COPILOT_HOME` | Overrides `~/.copilot` | Relocates Copilot CLI's user configuration, MCP config, custom agents, skills, hooks, and `session-state/` directory. |
| `BENTO_SYSTEM_ROOT` | Bento test-isolation root | Defaults to `/` in production; set to the fixture home root in `FixtureHome` tests. |

## Verified Path Catalog

| Entry ID | Pattern | Scope | Kind | Notes |
|---|---|---|---|---|
| `copilot.user.config` | `~/.copilot/config.json` | `user` | `settings` | CLI state file (trusted directories, model preferences); redacted at parse time. |
| `copilot.user.settings` | `~/.copilot/settings.json` | `user` | `settings` | Personal global settings (may also contain user `hooks`). |
| `copilot.user.instructions` | `~/.copilot/copilot-instructions.md` | `user` | `rules` | Personal global instructions loaded on every session (`always`). |
| `copilot.user.mcp` | `~/.copilot/mcp-config.json` | `user` | `mcpServer` | User-level `mcpServers` (`stdio`/`local`, `http`, `sse`, `tools` allowlist, `enabled`/`disabled`). |
| `copilot.user.agentsSkills` | `~/.agents/skills/*/SKILL.md` | `user` | `skill` | Cross-agent personal skills (`frontmatterOnly`); overrides `~/.copilot/skills` on duplicate names. |
| `copilot.user.copilotSkills` | `~/.copilot/skills/*/SKILL.md` | `user` | `skill` | Copilot personal skills (`frontmatterOnly`). |
| `copilot.user.agents` | `~/.copilot/agents/*.agent.md` | `user` | `subagent` | Personal custom agent profiles (`*.agent.md` / `*.md`) with YAML frontmatter. |
| `copilot.user.hooks` | `~/.copilot/hooks/*.json` | `user` | `hook` | Personal lifecycle hook definitions (`sessionStart`, `userPromptSubmitted`, `preToolUse`, `postToolUse`, `sessionEnd`). |
| `copilot.user.sessionLogs` | `~/.copilot/session-state/*/events.jsonl` | `user` | `settings` | Append-only per-session JSONL event log (`.jsonl` / `.jsonl.zst`); sibling `workspace.yaml` records `cwd`. |
| `copilot.project.instructions` | `<repo>/.github/copilot-instructions.md` | `project` | `rules` | Repository-wide custom instructions (`always`). |
| `copilot.project.modularInstructions` | `<repo>/.github/instructions/**/*.instructions.md` | `project` | `rules` | Path-scoped modular instructions; YAML frontmatter `applyTo` globs map to `LoadMode.conditional(globs:)`. |
| `copilot.project.agentsMd` | `<repo>/AGENTS.md` | `project` | `rules` | Root `AGENTS.md` instructions (`always`). |
| `copilot.directory.agentsMd` | `<subdir>/AGENTS.md` | `directory` | `rules` | Nested `AGENTS.md` instructions (`always` on ancestor path to `folder`, `conditional` for descendants). |
| `copilot.project.githubMcp` | `<repo>/.github/mcp.json` | `project` | `mcpServer` | Repository MCP configuration (`mcpServers` or `servers`); overrides `.vscode/mcp.json` and user `mcp-config.json`. |
| `copilot.project.vscodeMcp` | `<repo>/.vscode/mcp.json` | `project` | `mcpServer` | Workspace VS Code MCP configuration (`servers` or `mcpServers`); overrides user `mcp-config.json`. |
| `copilot.project.agentsSkills` | `<repo>/.agents/skills/*/SKILL.md` | `project` | `skill` | Workspace cross-agent skills; overrides `<repo>/.github/skills` and user skills. |
| `copilot.project.githubSkills` | `<repo>/.github/skills/*/SKILL.md` | `project` | `skill` | Repository Copilot skills (`frontmatterOnly`). |
| `copilot.project.agents` | `<repo>/.github/agents/*.agent.md` | `project` | `subagent` | Repository custom agent definitions; override user custom agents of the same name. |
| `copilot.project.prompts` | `<repo>/.github/prompts/*.prompt.md` | `project` | `command` | Reusable slash-command prompt files (`onInvoke`). |
| `copilot.project.hooks` | `<repo>/.github/hooks/*.json` | `project` | `hook` | Repository lifecycle hook definitions (`onInvoke`). |

## Precedence & Resolution Semantics

1. **Custom Instructions (`copilot-instructions.md`, `*.instructions.md`, `AGENTS.md`):**
   - Instruction files concatenate across scopes without shadowing: `~/.copilot/copilot-instructions.md` → ancestor `AGENTS.md` above repo → `<repo>/.github/copilot-instructions.md` → `<repo>/AGENTS.md` → intermediate `<subdir>/AGENTS.md` down to `folder` → modular `<repo>/.github/instructions/**/*.instructions.md` → descendant `<subdir>/AGENTS.md` (`conditional`).
   - In `.instructions.md` files, YAML frontmatter `applyTo` accepts a single glob string, comma-separated globs, or a YAML string array and resolves to `LoadMode.conditional(globs:)`. Files without `applyTo` default to `LoadMode.always`.

2. **MCP Servers (`mcp-config.json`, `.github/mcp.json`, `.vscode/mcp.json`):**
   - Precedence on duplicate server names: `<repo>/.github/mcp.json` > `<repo>/.vscode/mcp.json` > `~/.copilot/mcp-config.json`, recording shadowed entries in `Resolution.shadowed`.
   - `tools: ["*"]` allows all tools (`allowedTools = nil`), whereas explicit tool lists populate `MCPServerConfig.allowedTools`. `type: "local"` is normalized alongside `type: "stdio"`.

3. **Skills, Custom Agents, Prompts & Hooks:**
   - **Skills:** `<repo>/.agents/skills` > `<repo>/.github/skills` > `~/.agents/skills` > `~/.copilot/skills`.
   - **Custom Agents:** `<repo>/.github/agents` > `~/.copilot/agents`. Filenames ending in `.agent.md` strip the `.agent.md` suffix when deriving default agent names.
   - **Prompts & Hooks:** Prompt files strip `.prompt.md` for their command name and load `onInvoke`. Hooks support both Copilot CLI `{ "bash": "...", "timeoutSec": 30 }` and `{ "command": "...", "timeout": 30 }` entries.

4. **Session Event Log Schema (`CopilotLogDecoder`, verified `2026-10-31`):**
   - Path: `~/.copilot/session-state/<session-id>/events.jsonl` (and `.jsonl.zst`), with `inferredCwd` fallback read from sibling `workspace.yaml`.
   - Decodes `session.start` (`sessionId`, `cwd`, `data.selectedModel`), `session.model_change` (`data.newModel`), `tool.execution_start` (deduped by `data.toolCallId`, classifying explicit `data.mcpServerName` + `data.mcpToolName`, `mcp__<server>__<tool>`, `skill`, `agent`, and built-in tools), and `assistant.usage` (`inputTokens`, `cacheReadTokens`, `outputTokens`). Prompt and tool-argument content is never stored.
