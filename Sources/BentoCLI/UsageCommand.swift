import ArgumentParser
import BentoCore
import BentoLogIngest
import BentoScanner
import BentoStore
import BentoTokenizer
import Foundation

/// Summarizes privacy-safe session, token, skill, subagent, command, and MCP tool usage over a rolling
/// day window, joining active resolved artifacts by `"cost × unused"` and emitting `Finding.Kind.unused`
/// records (`PLAN.md` §6.2, §6.5, §6.8, §11 T11–T12).
struct UsageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "usage",
        abstract: "Summarize local agent token and tool/skill invocation usage."
    )

    @OptionGroup var common: CLICommonOptions

    @Option(name: .long, help: "Rolling lookback window in days (default: 30).")
    var days: Int = UsageJoinEngine.defaultWindowDays

    @Option(
        name: .customLong("min-sessions"),
        help: "Minimum sessions in window before flagging 0-invocation artifacts as unused (default: 5)."
    )
    var minSessions: Int = UsageJoinEngine.defaultMinimumSessions

    @Option(name: .long, help: "Optional repository path filter.")
    var repo: String?

    @Option(name: .long, help: "Optional agent identifier (claudeCode, codex, gemini, copilot).")
    var agent: String?

    mutating func run() async throws {
        guard days > 0 else {
            throw ValidationError("--days must be greater than 0.")
        }
        guard minSessions > 0 else {
            throw ValidationError("--min-sessions must be greater than 0.")
        }
        let parsedAgent = try agent.map { try CLICommonOptions.parseAgent($0) }
        let resolvedRepoURL = repo.map { CLICommonOptions.resolvePath($0) }
        let (env, store) = try common.makeRuntime()
        defer { try? store.close() }

        let workspace = Workspace(environment: env, store: store)
        let activeSnapshot = try await workspace.currentSnapshot()
        let discoveredRepos =
            if let snapRepos = activeSnapshot?.repos, !snapRepos.isEmpty {
                snapRepos
            } else {
                await workspace.discoverRepositories()
            }

        // When running hermetically against `--home` without `--db` (in-memory store), or if logs have
        // never been ingested yet into the target store, perform an incremental ingest pass automatically.
        let needsIngest = try store.databaseURL == nil || store.logFileStates().isEmpty
        if needsIngest {
            try store.syncDiscoveredRepos(discoveredRepos, seenAt: env.now())
            let targets = try await workspace.logIngestTargets(for: parsedAgent)
            _ = try await LogIngestor(fileSystem: env.fileSystem, store: store).ingest(targets: targets)
        }

        let now = env.now()
        let since = now.addingTimeInterval(-Double(days) * 86_400.0)
        // Use exact `now` when deterministic `BENTO_NOW_ISO8601` is set; otherwise tolerate slight future skew in static fixtures.
        let hasFixedClock = !(env.env["BENTO_NOW_ISO8601"] ?? "").isEmpty
        let until = hasFixedClock ? now : max(now, now.addingTimeInterval(86_400.0 * 3650.0))

        let canonicalRepoPath: String?
        if let resolvedRepoURL {
            if let activeSnapshot {
                canonicalRepoPath = activeSnapshot.resolveCanonicalRepoPath(resolvedRepoURL.path)
            } else {
                canonicalRepoPath = resolvedRepoURL.standardizedFileURL.path
            }
        } else {
            canonicalRepoPath = nil
        }

        let summary = try store.usageSummary(
            since: since,
            until: until,
            agent: parsedAgent,
            repoPath: canonicalRepoPath
        )

        var tokenizer = try AgentTokenizerRegistry()
        let storedCalibrations = try store.calibrations(for: parsedAgent)
        if !storedCalibrations.isEmpty {
            tokenizer.applyCalibrations(storedCalibrations)
        }
        var probesByHash: [String: MCPProbeRecord] = [:]
        for record in try store.allMCPProbes() where record.ok {
            probesByHash[record.serverConfigHash] = record
        }
        let fallbackEstimate = try store.mcpFallbackEstimate()

        let joinRepoPaths: [String]
        if let canonicalRepoPath {
            joinRepoPaths = [canonicalRepoPath]
        } else {
            joinRepoPaths = discoveredRepos.map(\.path)
        }

        let candidateAgents: [AgentID]
        if let parsedAgent {
            candidateAgents = workspace.budgetCapableAgents().contains(parsedAgent) ? [parsedAgent] : []
        } else {
            candidateAgents = workspace.budgetCapableAgents()
        }

        let joinEngine = UsageJoinEngine()
        var mergedItems: [ArtifactUsageJoin] = []
        var mergedFindings: [Finding] = []
        var seenFindingIDs: Set<String> = []

        for repoPath in joinRepoPaths {
            let repoURL = URL(fileURLWithPath: repoPath).standardizedFileURL
            guard env.fileSystem.exists(repoURL) else { continue }

            let repoUsageSummary: UsageSummary
            if repoPath == canonicalRepoPath {
                repoUsageSummary = summary
            } else {
                repoUsageSummary = try store.usageSummary(
                    since: since,
                    until: until,
                    agent: parsedAgent,
                    repoPath: repoPath
                )
            }
            let usageByAgent = Dictionary(uniqueKeysWithValues: repoUsageSummary.byAgent.map { ($0.agent, $0) })

            var agentInputs: [UsageJoinAgentInput] = []
            for agentID in candidateAgents {
                let (artifacts, resolution) = try await workspace.resolvedContext(
                    for: agentID,
                    folder: repoURL
                )
                let agentBudget = try await workspace.budget(
                    for: agentID,
                    folder: repoURL,
                    tokenizer: tokenizer,
                    mcpProbesByConfigHash: probesByHash,
                    mcpFallbackEstimate: fallbackEstimate,
                    measuredFirstTurnInput: usageByAgent[agentID]?.firstTurnMedianInput
                )
                agentInputs.append(
                    UsageJoinAgentInput(
                        agent: agentID,
                        artifacts: artifacts,
                        resolution: resolution,
                        budget: agentBudget,
                        fixSupport: workspace.fixSupport(for: agentID),
                        usage: usageByAgent[agentID]
                    )
                )
            }

            let report = joinEngine.join(
                repoPath: repoPath,
                windowDays: days,
                since: since,
                until: now,
                minimumSessions: minSessions,
                inputs: agentInputs
            )
            mergedItems.append(contentsOf: report.items)
            for finding in report.unusedFindings where seenFindingIDs.insert(finding.id).inserted {
                mergedFindings.append(finding)
            }
        }

        if joinRepoPaths.count > 1 {
            mergedItems.sort { lhs, rhs in
                if lhs.costTimesUnusedScore != rhs.costTimesUnusedScore {
                    return lhs.costTimesUnusedScore > rhs.costTimesUnusedScore
                }
                if lhs.tokensCostPerSession != rhs.tokensCostPerSession {
                    return lhs.tokensCostPerSession > rhs.tokensCostPerSession
                }
                if lhs.invocationCount != rhs.invocationCount {
                    return lhs.invocationCount < rhs.invocationCount
                }
                return lhs.id < rhs.id
            }
        }

        if let activeSnapshot, canonicalRepoPath == nil && parsedAgent == nil {
            try store.saveFindings(mergedFindings, snapshotID: activeSnapshot.id, replacingKind: .unused)
        } else if let activeSnapshot, !mergedFindings.isEmpty {
            try store.saveFindings(mergedFindings, snapshotID: activeSnapshot.id)
        }

        if common.json {
            let response = CLIJSONOutput.UsageResponse(
                generatedAt: now,
                days: days,
                minimumSessions: minSessions,
                since: since,
                until: now,
                agentFilter: parsedAgent?.rawValue,
                repoFilter: canonicalRepoPath,
                sessionCount: summary.sessionCount,
                eventCount: summary.eventCount,
                tokenTotals: summary.tokenTotals,
                byAgent: summary.byAgent,
                artifactUsage: mergedItems,
                unusedFindings: mergedFindings
            )
            try CLIJSONOutput.printJSON(response)
            return
        }

        print(
            "Usage (last \(days) days)\(canonicalRepoPath.map { " @ \($0)" } ?? ""):"
        )
        print(
            "Sessions: \(summary.sessionCount) | Events: \(summary.eventCount) | "
                + "Turns: \(summary.tokenTotals.turnCount)"
        )
        print(
            "Tokens — input: \(summary.tokenTotals.inputTokens), "
                + "cached: \(summary.tokenTotals.cachedInputTokens), "
                + "output: \(summary.tokenTotals.outputTokens)"
        )

        for agentSummary in summary.byAgent {
            print("")
            let medianStr = agentSummary.firstTurnMedianInput.map { " | 1st-turn median: \($0)" } ?? ""
            print(
                "  \(agentSummary.agent.rawValue): \(agentSummary.sessionCount) session(s), "
                    + "\(agentSummary.turnCount) turn(s), \(agentSummary.inputTokens) input tokens\(medianStr)"
            )
            if !agentSummary.skills.isEmpty {
                let items = agentSummary.skills.map { "\($0.name) (\($0.count))" }.joined(separator: ", ")
                print("    Skills: \(items)")
            }
            if !agentSummary.mcpTools.isEmpty {
                let items = agentSummary.mcpTools
                    .map { "\($0.server)/\($0.tool) (\($0.count))" }
                    .joined(separator: ", ")
                print("    MCP tools: \(items)")
            }
            if !agentSummary.subagents.isEmpty {
                let items = agentSummary.subagents.map { "\($0.name) (\($0.count))" }.joined(separator: ", ")
                print("    Subagents: \(items)")
            }
            if !agentSummary.commands.isEmpty {
                let items = agentSummary.commands.map { "/\($0.name) (\($0.count))" }.joined(separator: ", ")
                print("    Commands: \(items)")
            }
        }

        if !mergedFindings.isEmpty {
            print("")
            print("Unused findings (\(mergedFindings.count)):")
            for finding in mergedFindings {
                print("  [\(finding.severity.rawValue)] \(finding.message)")
            }
        }
    }
}
