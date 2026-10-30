/// Supported AI coding agents audited by the workspace.
public enum AgentID: String, Sendable, Codable, CaseIterable, Comparable {
    case claudeCode
    case codex
    case gemini
    case copilot
    case cursor
    case windsurf

    public static func < (lhs: AgentID, rhs: AgentID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
