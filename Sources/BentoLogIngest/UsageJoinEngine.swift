import BentoCore
import Foundation

/// Per-agent resolved context, token budget, fix capabilities, and aggregated usage passed into `UsageJoinEngine`.
public struct UsageJoinAgentInput: Sendable {
    public var agent: AgentID
    public var artifacts: [Artifact]
    public var resolution: Resolution
    public var budget: Budget
    public var fixSupport: FixSupport
    public var usage: AgentUsageSummary?

    public init(
        agent: AgentID,
        artifacts: [Artifact],
        resolution: Resolution,
        budget: Budget,
        fixSupport: FixSupport = FixSupport(),
        usage: AgentUsageSummary? = nil
    ) {
        self.agent = agent
        self.artifacts = artifacts
        self.resolution = resolution
        self.budget = budget
        self.fixSupport = fixSupport
        self.usage = usage
    }
}

/// Joins active resolved invokable artifacts (`.mcpServer`, `.skill`, `.subagent`, `.command`) with
/// per-repository session usage over a rolling day window, ranks items by `"cost × unused"`, and
/// emits `Finding.Kind.unused` records (`PLAN.md` §6.5, §6.7, §11 T12).
public struct UsageJoinEngine: Sendable {
    public static let defaultWindowDays = 30
    public static let defaultMinimumSessions = 5

    public init() {}

    public func join(
        repoPath: String,
        windowDays: Int = Self.defaultWindowDays,
        since: Date,
        until: Date,
        minimumSessions: Int = Self.defaultMinimumSessions,
        inputs: [UsageJoinAgentInput]
    ) -> UsageJoinReport {
        let stdRepoPath = URL(fileURLWithPath: repoPath).standardizedFileURL.path
        let effectiveMinSessions = max(1, minimumSessions)
        let effectiveDays = max(1, windowDays)

        struct CandidateResult {
            var joinItem: ArtifactUsageJoin
            var finding: Finding?
        }

        var candidates: [CandidateResult] = []

        for input in inputs {
            let artifactsByID = Dictionary(uniqueKeysWithValues: input.artifacts.map { ($0.id, $0) })

            var prePromptByArtifactID: [ArtifactID: Int] = [:]
            var deferredByArtifactID: [ArtifactID: Int] = [:]
            for item in input.budget.items {
                guard let artID = item.artifactID else { continue }
                if item.countsTowardPrePrompt {
                    prePromptByArtifactID[artID, default: 0] += item.tokens
                } else {
                    deferredByArtifactID[artID, default: 0] += item.tokens
                }
            }

            let sessionCount = input.usage?.sessionCount ?? 0

            // Collect active invokable artifacts in effective precedence order, deduplicating by ArtifactID.
            var seenArtifactIDs: Set<ArtifactID> = []
            var activeArtifacts: [Artifact] = []
            for resolved in input.resolution.ordered where resolved.effectiveLoadMode != .never {
                guard seenArtifactIDs.insert(resolved.artifactID).inserted,
                    let artifact = artifactsByID[resolved.artifactID],
                    artifact.enabled,
                    Self.isInvokableKind(artifact.kind)
                else {
                    continue
                }
                activeArtifacts.append(artifact)
            }

            let activeExactMCPNames = Set(
                activeArtifacts
                    .filter { $0.kind == .mcpServer }
                    .map { Self.normalizeBasic($0.name) }
            )
            let activeExactSkillNames = Set(
                activeArtifacts
                    .filter { $0.kind == .skill }
                    .map { Self.normalizeInvokable($0.name) }
            )

            for artifact in activeArtifacts {
                let prePromptCost = prePromptByArtifactID[artifact.id] ?? 0
                let deferredCost = deferredByArtifactID[artifact.id] ?? 0
                let (invocations, lastUsed) = Self.matchInvocations(
                    for: artifact,
                    usage: input.usage,
                    activeExactMCPNames: activeExactMCPNames,
                    activeExactSkillNames: activeExactSkillNames
                )

                let joinItem = ArtifactUsageJoin(
                    artifactID: artifact.id,
                    agent: input.agent,
                    kind: artifact.kind,
                    name: artifact.name,
                    scope: artifact.scope,
                    path: artifact.location.path,
                    tokensCostPerSession: prePromptCost,
                    deferredTokensEstimate: deferredCost,
                    invocationCount: invocations,
                    lastUsedAt: lastUsed,
                    sessionCountInWindow: sessionCount,
                    windowDays: effectiveDays
                )

                let finding: Finding?
                if Self.isUnusedCandidateKind(artifact.kind),
                    sessionCount >= effectiveMinSessions,
                    invocations == 0,
                    prePromptCost > 0 || deferredCost > 0
                {
                    finding = Self.buildUnusedFinding(
                        artifact: artifact,
                        agent: input.agent,
                        repoPath: stdRepoPath,
                        prePromptCost: prePromptCost,
                        deferredCost: deferredCost,
                        sessionCount: sessionCount,
                        windowDays: effectiveDays,
                        fixSupport: input.fixSupport
                    )
                } else {
                    finding = nil
                }

                candidates.append(CandidateResult(joinItem: joinItem, finding: finding))
            }
        }

        candidates.sort { lhs, rhs in
            Self.sortsBefore(lhs.joinItem, rhs.joinItem)
        }

        return UsageJoinReport(
            repoPath: stdRepoPath,
            windowDays: effectiveDays,
            since: since,
            until: until,
            minimumSessions: effectiveMinSessions,
            items: candidates.map(\.joinItem),
            unusedFindings: candidates.compactMap(\.finding)
        )
    }

    // MARK: - Private Matching & Ranking Helpers

    private static func isInvokableKind(_ kind: ArtifactKind) -> Bool {
        switch kind {
        case .mcpServer, .skill, .subagent, .command:
            return true
        case .rules, .hook, .settings, .plugin, .outputStyle, .ignoreFile:
            return false
        }
    }

    private static func isUnusedCandidateKind(_ kind: ArtifactKind) -> Bool {
        switch kind {
        case .mcpServer, .skill, .subagent:
            return true
        case .command, .rules, .hook, .settings, .plugin, .outputStyle, .ignoreFile:
            return false
        }
    }

    private static func matchInvocations(
        for artifact: Artifact,
        usage: AgentUsageSummary?,
        activeExactMCPNames: Set<String>,
        activeExactSkillNames: Set<String>
    ) -> (count: Int, lastUsedAt: Date?) {
        guard let usage else {
            return (0, nil)
        }

        var totalCount = 0
        var latestDate: Date?

        func accumulate(count: Int, date: Date) {
            totalCount += count
            if let existing = latestDate {
                if date > existing {
                    latestDate = date
                }
            } else {
                latestDate = date
            }
        }

        switch artifact.kind {
        case .mcpServer:
            let exactTarget = normalizeBasic(artifact.name)
            let canonicalTarget = canonicalMCPServerKey(artifact.name)
            for toolSummary in usage.mcpTools {
                let rawServer = normalizeBasic(toolSummary.server)
                let matched: Bool
                if rawServer == exactTarget {
                    matched = true
                } else if !activeExactMCPNames.contains(rawServer)
                    && canonicalMCPServerKey(toolSummary.server) == canonicalTarget
                {
                    matched = true
                } else {
                    matched = false
                }
                if matched {
                    accumulate(count: toolSummary.count, date: toolSummary.lastUsedAt)
                }
            }

        case .skill:
            let target = normalizeInvokable(artifact.name)
            for skillSummary in usage.skills {
                let logged = normalizeInvokable(skillSummary.name)
                if logged == target {
                    accumulate(count: skillSummary.count, date: skillSummary.lastUsedAt)
                } else if !activeExactSkillNames.contains(logged),
                    let colonIndex = logged.lastIndex(of: ":"),
                    String(logged[logged.index(after: colonIndex)...]) == target
                {
                    accumulate(count: skillSummary.count, date: skillSummary.lastUsedAt)
                }
            }

        case .subagent:
            let target = normalizeSubagent(artifact.name)
            for subSummary in usage.subagents where normalizeSubagent(subSummary.name) == target {
                accumulate(count: subSummary.count, date: subSummary.lastUsedAt)
            }

        case .command:
            let target = normalizeInvokable(artifact.name)
            for cmdSummary in usage.commands where normalizeInvokable(cmdSummary.name) == target {
                accumulate(count: cmdSummary.count, date: cmdSummary.lastUsedAt)
            }

        case .rules, .hook, .settings, .plugin, .outputStyle, .ignoreFile:
            break
        }

        return (totalCount, latestDate)
    }

    private static func buildUnusedFinding(
        artifact: Artifact,
        agent: AgentID,
        repoPath: String,
        prePromptCost: Int,
        deferredCost: Int,
        sessionCount: Int,
        windowDays: Int,
        fixSupport: FixSupport
    ) -> Finding {
        let identity = "unused|\(agent.rawValue)|\(repoPath)|\(artifact.id.rawValue)"
        let findingID = ContentHasher.sha256Hex(Data(identity.utf8))
        let kindLabel: String
        let candidateFixes: [FixKind]

        switch artifact.kind {
        case .mcpServer:
            kindLabel = "MCP server"
            candidateFixes = [.disableMCPServer]
        case .skill:
            kindLabel = "Skill"
            candidateFixes = [.disableSkill, .trashArtifact]
        case .subagent:
            kindLabel = "Subagent"
            candidateFixes = [.trashArtifact]
        default:
            kindLabel = artifact.kind.rawValue
            candidateFixes = []
        }

        let supportedFixes = candidateFixes.filter { fixSupport.supportedKinds.contains($0) }
        let costDescription =
            prePromptCost > 0
            ? "\(prePromptCost) pre-prompt tokens/session (\(prePromptCost * sessionCount) tokens across \(sessionCount) sessions)"
            : "\(deferredCost) deferred tokens/session"

        let message =
            "\(kindLabel) '\(artifact.name)' (\(agent.rawValue)) had 0 invocations over \(windowDays) days "
            + "across \(sessionCount) sessions while costing \(costDescription)."

        return Finding(
            id: findingID,
            kind: .unused,
            severity: prePromptCost > 0 ? .warning : .info,
            artifacts: [artifact.id],
            spans: [artifact.location],
            message: message,
            suggestedFixes: supportedFixes
        )
    }

    private static func sortsBefore(_ lhs: ArtifactUsageJoin, _ rhs: ArtifactUsageJoin) -> Bool {
        if lhs.costTimesUnusedScore != rhs.costTimesUnusedScore {
            return lhs.costTimesUnusedScore > rhs.costTimesUnusedScore
        }
        if lhs.tokensCostPerSession != rhs.tokensCostPerSession {
            return lhs.tokensCostPerSession > rhs.tokensCostPerSession
        }
        if lhs.invocationCount != rhs.invocationCount {
            return lhs.invocationCount < rhs.invocationCount
        }
        if lhs.deferredTokensEstimate != rhs.deferredTokensEstimate {
            return lhs.deferredTokensEstimate > rhs.deferredTokensEstimate
        }
        if lhs.agent.rawValue != rhs.agent.rawValue {
            return lhs.agent.rawValue < rhs.agent.rawValue
        }
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        if lhs.name != rhs.name {
            return lhs.name < rhs.name
        }
        return lhs.artifactID.rawValue < rhs.artifactID.rawValue
    }

    private static func normalizeBasic(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizeInvokable(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("/") {
            trimmed.removeFirst()
        }
        return trimmed.lowercased()
    }

    private static func normalizeSubagent(_ raw: String) -> String {
        var norm = normalizeInvokable(raw)
        if norm.hasSuffix(".agent.md") {
            norm = String(norm.dropLast(".agent.md".count))
        } else if norm.hasSuffix(".md") {
            norm = String(norm.dropLast(".md".count))
        }
        return norm
    }

    private static func canonicalMCPServerKey(_ raw: String) -> String {
        let lower = normalizeBasic(raw)
        var scalars = String.UnicodeScalarView()
        for scalar in lower.unicodeScalars {
            if scalar == "-" || scalar == "." || scalar == " " {
                scalars.append("_")
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}
