import ArgumentParser
import BentoCore
import BentoMCPProbe
import BentoScanner
import BentoStore
import BentoTokenizer
import Foundation

/// Computes per-agent context token budgets (built-ins, rules, skills, subagents, commands, hooks, MCP tools)
/// for a target repository, optionally probing explicitly consented MCP servers (`PLAN.md` §6.4, §6.8, §11 T09–T10).
struct BudgetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "budget",
        abstract: "Estimate pre-prompt and deferred context token budgets for a repository."
    )

    @OptionGroup var common: CLICommonOptions

    @Option(name: .long, help: "Target repository or working directory path.")
    var repo: String

    @Option(name: .long, help: "Optional agent identifier (claudeCode, codex, gemini, copilot).")
    var agent: String?

    @Option(name: .long, help: "Optional model identifier override for tokenization and built-in overhead.")
    var model: String?

    @Option(
        name: .customLong("probe-mcp"),
        help: "Explicitly consent to and probe the named MCP server(s) (repeatable or comma-separated; '*' for all)."
    )
    var probeMCP: [String] = []

    mutating func run() async throws {
        let parsedAgent = try agent.map { try CLICommonOptions.parseAgent($0) }
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveModelOverride = (trimmedModel?.isEmpty == false) ? trimmedModel : nil
        let requestedProbeNames = Self.parseRequestedServerNames(probeMCP)
        let repoURL = CLICommonOptions.resolvePath(repo)
        let (env, store) = try common.makeRuntime()
        defer { try? store.close() }

        let tokenizer = try AgentTokenizerRegistry()
        let workspace = Workspace(environment: env, store: store)

        let existingSnapshot = try await workspace.currentSnapshot()
        let activeSnapshot: Snapshot?
        if let existingSnapshot {
            activeSnapshot = existingSnapshot
        } else if store.databaseURL != nil {
            activeSnapshot = try await workspace.scanFull()
        } else {
            activeSnapshot = nil
        }

        let snapshotID = activeSnapshot?.id ?? "on-demand-\(UUID().uuidString.lowercased())"
        let canonicalRepoPath = activeSnapshot?.resolveCanonicalRepoPath(repoURL.path) ?? repoURL.path
        let targetURL = URL(fileURLWithPath: canonicalRepoPath).standardizedFileURL

        if !requestedProbeNames.isEmpty {
            let consentStore = try MCPConsentStore(persistence: store)
            let prober = MCPProber(
                consentStore: consentStore,
                cache: store,
                now: env.now
            )
            let mcpTargets = try await workspace.resolvedMCPServers(
                for: parsedAgent,
                folder: targetURL
            )
            let probeAll = requestedProbeNames.contains("*")

            for target in mcpTargets {
                guard probeAll || requestedProbeNames.contains(target.artifact.name) else {
                    continue
                }
                try consentStore.grantConsent(for: target.config)
                let declaredValues = MCPEnvironmentResolver.resolveDeclaredEnvValues(
                    for: target.artifact,
                    config: target.config,
                    in: env
                )
                do {
                    _ = try await prober.probe(
                        serverName: target.artifact.name,
                        agent: target.agent,
                        config: target.config,
                        workingDirectory: targetURL,
                        homeDirectory: env.home,
                        basePATH: env.env["PATH"] ?? ProcessInfo.processInfo.environment["PATH"],
                        declaredEnvValues: declaredValues,
                        model: effectiveModelOverride,
                        tokenizer: tokenizer
                    )
                } catch {
                    Self.writeStderrWarning("warning: \(error)\n")
                }
            }
        }

        var probesByHash: [String: MCPProbeRecord] = [:]
        for record in try store.allMCPProbes() where record.ok {
            probesByHash[record.serverConfigHash] = record
        }
        let fallbackEstimate = try store.mcpFallbackEstimate()

        let budgets: [Budget]
        if let parsedAgent {
            let single = try await workspace.budget(
                for: parsedAgent,
                folder: targetURL,
                model: effectiveModelOverride,
                tokenizer: tokenizer,
                mcpProbesByConfigHash: probesByHash,
                mcpFallbackEstimate: fallbackEstimate
            )
            budgets = [single]
        } else {
            budgets = try await workspace.budgets(
                folder: targetURL,
                model: effectiveModelOverride,
                tokenizer: tokenizer,
                mcpProbesByConfigHash: probesByHash,
                mcpFallbackEstimate: fallbackEstimate
            )
        }

        if activeSnapshot != nil {
            for budget in budgets {
                try store.saveBudget(budget, snapshotID: snapshotID)
            }
        }

        if common.json {
            let response = CLIJSONOutput.BudgetResponse(
                generatedAt: env.now(),
                snapshotID: snapshotID,
                repoPath: canonicalRepoPath,
                agentFilter: parsedAgent?.rawValue,
                modelOverride: effectiveModelOverride,
                budgets: budgets
            )
            try CLIJSONOutput.printJSON(response)
            return
        }

        for (idx, budget) in budgets.enumerated() {
            if idx > 0 {
                print("")
            }
            let modelSuffix = budget.model.map { " (model: \($0))" } ?? ""
            print("Budget: \(budget.agent.rawValue) @ \(budget.folder)\(modelSuffix)")
            if let window = budget.contextWindow, window > 0 {
                let pct = (Double(budget.prePromptTokens) / Double(window)) * 100.0
                print(
                    String(
                        format: "  Pre-prompt tokens: %d / %d (%.1f%%)",
                        budget.prePromptTokens,
                        window,
                        pct
                    )
                )
            } else {
                print("  Pre-prompt tokens: \(budget.prePromptTokens)")
            }
            print("  Items (\(budget.items.count)):")
            for item in budget.items {
                let tag = item.countsTowardPrePrompt ? "pre-prompt" : "excluded  "
                print(
                    "    [\(tag)] \(item.category.rawValue): \(item.label) — "
                        + "\(item.tokens) tokens (\(item.confidence.rawValue), \(item.method))"
                )
            }
        }
    }

    private static func parseRequestedServerNames(_ rawValues: [String]) -> Set<String> {
        var names: Set<String> = []
        for raw in rawValues {
            for part in raw.split(separator: ",") {
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    names.insert(trimmed)
                }
            }
        }
        return names
    }

    private static func writeStderrWarning(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
    }
}
