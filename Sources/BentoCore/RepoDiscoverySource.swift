/// Provenance tag indicating how a repository directory was discovered (PLAN §5.3).
public enum RepoDiscoverySource: String, Sendable, Codable, Hashable, Comparable, CaseIterable {
    /// Listed under `projects` in Claude Code's `~/.claude.json`.
    case claudeState
    /// Decoded from `~/.claude/projects/<encoded-cwd>` or Claude session JSONL `cwd`.
    case claudeLogs
    /// Listed under `[projects.*]` in Codex's `~/.codex/config.toml`.
    case codexConfig
    /// Extracted from `session_meta` `cwd` in Codex rollout logs.
    case codexLogs
    /// Matched against SHA-256 `<project-hash>` (or `.project_root`) in `~/.gemini/tmp/`.
    case geminiLogs
    /// Listed in `trusted_folders` in Copilot CLI's `~/.copilot/config.json`.
    case copilotConfig
    /// Extracted from `workspace.yaml` or `events.jsonl` in `~/.copilot/session-state/`.
    case copilotLogs
    /// Explicitly added or pinned by the user.
    case manual
    /// Found via optional shallow `.git` scan (`~/Developer`, `~/code`, `~/src`, `~/Projects`).
    case shallowScan

    public static func < (lhs: RepoDiscoverySource, rhs: RepoDiscoverySource) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
