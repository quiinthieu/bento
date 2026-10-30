import BentoCore

/// Registry of all built-in `AgentAdapter` implementations in deterministic `AgentID.allCases` order.
public enum AgentAdapters: Sendable {
    /// Returns one fresh instance of every supported v1 `AgentAdapter`.
    public static var all: [any AgentAdapter] {
        [
            ClaudeCodeAdapter(),
            CodexAdapter(),
            GeminiAdapter(),
            CopilotAdapter(),
            CursorAdapter(),
            WindsurfAdapter()
        ]
    }

    /// Returns the adapter instance matching `id`.
    public static func adapter(for id: AgentID) -> any AgentAdapter {
        switch id {
        case .claudeCode:
            ClaudeCodeAdapter()
        case .codex:
            CodexAdapter()
        case .gemini:
            GeminiAdapter()
        case .copilot:
            CopilotAdapter()
        case .cursor:
            CursorAdapter()
        case .windsurf:
            WindsurfAdapter()
        }
    }
}
