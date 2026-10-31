import Foundation

/// Joins an active resolved invokable `Artifact` (`.mcpServer`, `.skill`, `.subagent`, `.command`)
/// with its per-session pre-prompt token cost and observed usage over a rolling day window (`PLAN.md` §6.5, §6.7, §11 T12).
public struct ArtifactUsageJoin: Sendable, Codable, Hashable, Identifiable {
    public var id: String {
        "\(agent.rawValue):\(artifactID.rawValue)"
    }

    public var artifactID: ArtifactID
    public var agent: AgentID
    public var kind: ArtifactKind
    public var name: String
    public var scope: Scope
    public var path: String
    public var tokensCostPerSession: Int
    public var deferredTokensEstimate: Int
    public var invocationCount: Int
    public var lastUsedAt: Date?
    public var sessionCountInWindow: Int
    public var windowDays: Int
    public var costTimesUnusedScore: Int

    public init(
        artifactID: ArtifactID,
        agent: AgentID,
        kind: ArtifactKind,
        name: String,
        scope: Scope,
        path: String,
        tokensCostPerSession: Int,
        deferredTokensEstimate: Int = 0,
        invocationCount: Int,
        lastUsedAt: Date? = nil,
        sessionCountInWindow: Int,
        windowDays: Int,
        costTimesUnusedScore: Int? = nil
    ) {
        self.artifactID = artifactID
        self.agent = agent
        self.kind = kind
        self.name = name
        self.scope = scope
        self.path = path
        self.tokensCostPerSession = tokensCostPerSession
        self.deferredTokensEstimate = deferredTokensEstimate
        self.invocationCount = invocationCount
        self.lastUsedAt = lastUsedAt
        self.sessionCountInWindow = sessionCountInWindow
        self.windowDays = windowDays
        if let explicitScore = costTimesUnusedScore {
            self.costTimesUnusedScore = explicitScore
        } else {
            self.costTimesUnusedScore =
                invocationCount == 0
                ? tokensCostPerSession * max(1, sessionCountInWindow)
                : 0
        }
    }
}

/// Complete usage-to-artifact join report for a repository over `[since, until]`, ranked by `"cost × unused"`
/// alongside emitted `Finding.Kind.unused` records (`PLAN.md` §6.5, §6.7, §11 T12).
public struct UsageJoinReport: Sendable, Codable, Hashable {
    public var repoPath: String
    public var windowDays: Int
    public var since: Date
    public var until: Date
    public var minimumSessions: Int
    public var items: [ArtifactUsageJoin]
    public var unusedFindings: [Finding]

    public init(
        repoPath: String,
        windowDays: Int,
        since: Date,
        until: Date,
        minimumSessions: Int,
        items: [ArtifactUsageJoin],
        unusedFindings: [Finding]
    ) {
        self.repoPath = repoPath
        self.windowDays = windowDays
        self.since = since
        self.until = until
        self.minimumSessions = minimumSessions
        self.items = items
        self.unusedFindings = unusedFindings
    }
}
