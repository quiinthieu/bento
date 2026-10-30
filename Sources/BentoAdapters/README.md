# BentoAdapters

`BentoAdapters` contains per-agent `AgentAdapter` implementations, each driven exclusively by a verified `PathCatalog` for read-only discovery, folder-scoped precedence resolution, context budget contributions, log discovery/decoding, and reversible fix capability metadata:

- **`AdapterPathNormalizer`:** Shared `<HOME>` canonical identity hashing, `BENTO_SYSTEM_ROOT` isolation, and cycle-safe sorted `ReadOnlyFileSystem` traversal.
- **`ClaudeCode/` (`ClaudeCodeAdapter`):** Verified Claude Code integration (`Docs/adapters/claude-code.md`) covering managed/projectLocal/project/user settings precedence, `.mcp.json` trust & approval gating (`enabledMcpjsonServers`, `disabledMcpjsonServers`, `enableAllProjectMcpServers`, enterprise `deniedMcpServers`), nested `CLAUDE.md` / `CLAUDE.local.md` concatenation and `@path` imports, `.claude/rules/` `paths:` conditional globs, skills, cached plugins (`installed_plugins.json` + `enabledPlugins`), subagents, slash commands, 3-level lifecycle hooks, and session log discovery.
