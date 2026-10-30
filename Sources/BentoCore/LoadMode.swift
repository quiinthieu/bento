/// Describes when and how an artifact enters the agent's context window.
public enum LoadMode: Sendable, Codable, Hashable {
    /// Loaded unconditionally into every session's pre-prompt context (e.g. `CLAUDE.md`, `AGENTS.md`).
    case always
    /// Frontmatter (`name` + `description`) is loaded upfront; full body loads only upon invocation.
    case frontmatterOnly
    /// Tool schemas are deferred behind tool-search or lazy loading with a small stub cost.
    case deferred
    /// Loaded strictly on explicit user/agent invocation (commands, subagent bodies).
    case onInvoke
    /// Loaded conditionally when active file paths match one or more glob patterns.
    case conditional(globs: [String])
    /// Disabled; never loaded into context.
    case never
}
