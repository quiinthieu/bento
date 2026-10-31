import ArgumentParser
import BentoCore
import BentoLogIngest
import BentoScanner
import BentoStore
import Foundation

/// Summarizes privacy-safe session, token, skill, subagent, command, and MCP tool usage over a rolling
/// day window (`PLAN.md` §6.2, §6.8, §11 T11).
struct UsageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "usage",
        abstract: "Summarize local agent token and tool/skill invocation usage."
    )

    @OptionGroup var common: CLICommonOptions

    @Option(name: .long, help: "Rolling lookback window in days (default: 30).")
    var days: Int = 30

    @Option(name: .long, help: "Optional repository path filter.")
    var repo: String?

    @Option(name: .long, help: "Optional agent identifier (claudeCode, codex, gemini, copilot).")
    var agent: String?

    mutating func run() async throws {
        guard days > 0 else {
            throw ValidationError("--days must be greater than 0.")
        }
        let parsedAgent = try agent.map { try CLICommonOptions.parseAgent($0) }
        let resolvedRepoURL = repo.map { CLICommonOptions.resolvePath($0) }
        let (env, store) = try common.makeRuntime()
        defer { try? store.close() }

        let workspace = Workspace(environment: env, store: store)

        // When running hermetically against `--home` without `--db` (in-memory store), or if logs have
        // never been ingested yet into the target store, perform an incremental ingest pass automatically.
        let needsIngest = try store.databaseURL == nil || store.logFileStates().isEmpty
        if needsIngest {
            let repos = await workspace.discoverRepositories()
            try store.syncDiscoveredRepos(repos, seenAt: env.now())
            let targets = try await workspace.logIngestTargets(for: parsedAgent)
            _ = try await LogIngestor(fileSystem: env.fileSystem, store: store).ingest(targets: targets)
        }

        let now = env.now()
        let since = now.addingTimeInterval(-Double(days) * 86_400.0)
        // Allow slight future skew in synthetic fixture logs relative to wall-clock `now`.
        let until = max(now, now.addingTimeInterval(86_400.0 * 3650.0))

        let canonicalRepoPath: String?
        if let resolvedRepoURL {
            if let snapshot = try await workspace.currentSnapshot() {
                canonicalRepoPath = snapshot.resolveCanonicalRepoPath(resolvedRepoURL.path)
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

        if common.json {
            let response = CLIJSONOutput.UsageResponse(
                generatedAt: now,
                days: days,
                since: since,
                until: now,
                agentFilter: parsedAgent?.rawValue,
                repoFilter: canonicalRepoPath,
                sessionCount: summary.sessionCount,
                eventCount: summary.eventCount,
                tokenTotals: summary.tokenTotals,
                byAgent: summary.byAgent
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
    }
}
