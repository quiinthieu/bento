import Foundation

/// Privacy-preserving telemetry record decoded from local agent session logs.
/// Prompt and response text is never extracted or stored.
public struct UsageEvent: Sendable, Codable, Hashable {
    /// Specific event payload decoded from a log line.
    public enum Kind: Sendable, Codable, Hashable {
        case sessionStart(model: String?)
        case tokenUsage(input: Int, cachedInput: Int?, output: Int, turnIndex: Int)
        case skillInvoked(name: String)
        case mcpToolCalled(server: String, tool: String)
        case subagentInvoked(name: String)
        case commandInvoked(name: String)
        case builtinToolCalled(name: String)
    }

    /// Agent whose log produced this event.
    public var agent: AgentID
    /// Agent-assigned session identifier.
    public var sessionID: String
    /// Event timestamp.
    public var timestamp: Date
    /// Working directory associated with the session, if known.
    public var cwd: String?
    /// Event kind and counts/identifiers.
    public var kind: Kind

    /// Creates a usage event record.
    public init(
        agent: AgentID,
        sessionID: String,
        timestamp: Date,
        cwd: String? = nil,
        kind: Kind
    ) {
        self.agent = agent
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.cwd = cwd
        self.kind = kind
    }
}
