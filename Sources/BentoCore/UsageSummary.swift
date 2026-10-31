import Foundation

/// Token consumption totals aggregated across matching `UsageEvent.Kind.tokenUsage` records.
public struct UsageTokenTotals: Sendable, Codable, Hashable {
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var turnCount: Int

    public init(
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        turnCount: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.turnCount = turnCount
    }
}

/// Aggregated invocation count and last-seen timestamp for a named skill, subagent, command, or built-in tool.
public struct InvocationSummary: Sendable, Codable, Hashable {
    public var name: String
    public var count: Int
    public var lastUsedAt: Date

    public init(name: String, count: Int, lastUsedAt: Date) {
        self.name = name
        self.count = count
        self.lastUsedAt = lastUsedAt
    }
}

/// Aggregated invocation count and last-seen timestamp for an MCP server tool (`mcp__<server>__<tool>`).
public struct MCPToolInvocationSummary: Sendable, Codable, Hashable {
    public var server: String
    public var tool: String
    public var count: Int
    public var lastUsedAt: Date

    public init(server: String, tool: String, count: Int, lastUsedAt: Date) {
        self.server = server
        self.tool = tool
        self.count = count
        self.lastUsedAt = lastUsedAt
    }
}

/// Per-agent usage aggregation over a time window and optional repository filter.
public struct AgentUsageSummary: Sendable, Codable, Hashable {
    public var agent: AgentID
    public var sessionCount: Int
    public var turnCount: Int
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var firstTurnMedianInput: Int?
    public var skills: [InvocationSummary]
    public var mcpTools: [MCPToolInvocationSummary]
    public var subagents: [InvocationSummary]
    public var commands: [InvocationSummary]
    public var builtinTools: [InvocationSummary]

    public init(
        agent: AgentID,
        sessionCount: Int,
        turnCount: Int,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        firstTurnMedianInput: Int? = nil,
        skills: [InvocationSummary] = [],
        mcpTools: [MCPToolInvocationSummary] = [],
        subagents: [InvocationSummary] = [],
        commands: [InvocationSummary] = [],
        builtinTools: [InvocationSummary] = []
    ) {
        self.agent = agent
        self.sessionCount = sessionCount
        self.turnCount = turnCount
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.firstTurnMedianInput = firstTurnMedianInput
        self.skills = skills
        self.mcpTools = mcpTools
        self.subagents = subagents
        self.commands = commands
        self.builtinTools = builtinTools
    }
}

/// Cross-agent usage summary returned by `BentoStore.usageSummary(...)` and `bentoctx usage --json`.
public struct UsageSummary: Sendable, Codable, Hashable {
    public var since: Date
    public var until: Date
    public var agentFilter: AgentID?
    public var repoFilter: String?
    public var sessionCount: Int
    public var eventCount: Int
    public var tokenTotals: UsageTokenTotals
    public var byAgent: [AgentUsageSummary]

    public init(
        since: Date,
        until: Date,
        agentFilter: AgentID? = nil,
        repoFilter: String? = nil,
        sessionCount: Int,
        eventCount: Int,
        tokenTotals: UsageTokenTotals,
        byAgent: [AgentUsageSummary]
    ) {
        self.since = since
        self.until = until
        self.agentFilter = agentFilter
        self.repoFilter = repoFilter
        self.sessionCount = sessionCount
        self.eventCount = eventCount
        self.tokenTotals = tokenTotals
        self.byAgent = byAgent
    }
}
