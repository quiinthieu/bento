import ArgumentParser
import BentoCore
import BentoLogIngest
import BentoMCPProbe
import BentoScanner
import BentoStore
import BentoTokenizer
import Foundation

/// Computes per-agent context token budgets (built-ins, rules, skills, subagents, commands, hooks, MCP tools)
/// for a target repository, fitting/applying log calibrations, attaching measured first-turn medians, and
/// optionally probing explicitly consented MCP servers (`PLAN.md` §6.3, §6.4, §6.8, §11 T09–T12).
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

    @Option(
        name: .long,
        help: "Opt-in exact token-counting API provider(s) using Keychain keys (anthropic, gemini)."
    )
    var api: [String] = []

    mutating func run() async throws {
        let parsedAgent = try agent.map { try CLICommonOptions.parseAgent($0) }
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveModelOverride = (trimmedModel?.isEmpty == false) ? trimmedModel : nil
        let requestedProbeNames = Self.parseCSVTokens(probeMCP)
        let requestedAPIProviders = try Self.parseAPIProviders(api)
        let repoURL = CLICommonOptions.resolvePath(repo)
        let (env, store) = try common.makeRuntime()
        defer { try? store.close() }

        let uncalibratedTokenizer = try AgentTokenizerRegistry()
        var tokenizer = uncalibratedTokenizer
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

        // Ensure local session logs are ingested so measuredFirstTurnInput and calibration factors are populated.
        let needsIngest = try store.databaseURL == nil || store.logFileStates().isEmpty
        if needsIngest {
            let repos: [DiscoveredRepo]
            if let snapRepos = activeSnapshot?.repos {
                repos = snapRepos
            } else {
                repos = await workspace.discoverRepositories()
            }
            try store.syncDiscoveredRepos(repos, seenAt: env.now())
            let logTargets = try await workspace.logIngestTargets(for: parsedAgent)
            _ = try await LogIngestor(fileSystem: env.fileSystem, store: store).ingest(targets: logTargets)
        }

        var probesByHash: [String: MCPProbeRecord] = [:]
        for record in try store.allMCPProbes() where record.ok {
            probesByHash[record.serverConfigHash] = record
        }
        var fallbackEstimate = try store.mcpFallbackEstimate()

        // Fit least-squares k-factor calibrations when >= 3 session samples exist per (agent, model, tokenizer).
        let calibrationSessions = try store.calibrationSessions(agent: parsedAgent)
        if calibrationSessions.count >= CalibrationFitter.defaultMinimumSamples {
            let fitted = try await Self.fitCalibrations(
                sessions: calibrationSessions,
                workspace: workspace,
                uncalibratedTokenizer: uncalibratedTokenizer,
                probesByHash: probesByHash,
                fallbackEstimate: fallbackEstimate,
                fileSystem: env.fileSystem,
                now: env.now()
            )
            if !fitted.isEmpty {
                try store.upsertCalibrations(fitted)
            }
        }
        let persistedCalibrations = try store.calibrations(for: parsedAgent)
        if !persistedCalibrations.isEmpty {
            tokenizer.applyCalibrations(persistedCalibrations)
        }

        // Configure opt-in exact token-counting APIs ONLY when explicitly requested via `--api`.
        if !requestedAPIProviders.isEmpty {
            let keyStore = KeychainAPIKeyStore()
            for provider in requestedAPIProviders {
                switch provider {
                case .anthropic:
                    if (try? keyStore.apiKey(for: .anthropic)) != nil {
                        let counter = AnthropicCountTokens(isEnabled: true, keyProvider: keyStore)
                        tokenizer.setExactAPICounter(counter, for: .claudeCode)
                    } else {
                        Self.writeStderrWarning(
                            "warning: --api anthropic requested but no Anthropic API key is stored in Keychain; using offline counter.\n"
                        )
                    }
                case .gemini:
                    if (try? keyStore.apiKey(for: .gemini)) != nil {
                        let counter = GeminiCountTokens(isEnabled: true, keyProvider: keyStore)
                        tokenizer.setExactAPICounter(counter, for: .gemini)
                    } else {
                        Self.writeStderrWarning(
                            "warning: --api gemini requested but no Gemini API key is stored in Keychain; using offline counter.\n"
                        )
                    }
                }
            }
        }

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

            probesByHash.removeAll(keepingCapacity: true)
            for record in try store.allMCPProbes() where record.ok {
                probesByHash[record.serverConfigHash] = record
            }
            fallbackEstimate = try store.mcpFallbackEstimate()
        }

        let candidateAgents = parsedAgent.map { [$0] } ?? workspace.budgetCapableAgents()
        var measuredByAgent: [AgentID: Int] = [:]
        for agentID in candidateAgents {
            if let median = try store.measuredFirstTurnMedianInput(
                agent: agentID,
                repoPath: targetURL.path,
                model: effectiveModelOverride
            ) {
                measuredByAgent[agentID] = median
            }
        }

        let budgets: [Budget]
        if let parsedAgent {
            let single = try await workspace.budget(
                for: parsedAgent,
                folder: targetURL,
                model: effectiveModelOverride,
                tokenizer: tokenizer,
                mcpProbesByConfigHash: probesByHash,
                mcpFallbackEstimate: fallbackEstimate,
                measuredFirstTurnInput: measuredByAgent[parsedAgent]
            )
            budgets = [single]
        } else {
            budgets = try await workspace.budgets(
                folder: targetURL,
                model: effectiveModelOverride,
                tokenizer: tokenizer,
                mcpProbesByConfigHash: probesByHash,
                mcpFallbackEstimate: fallbackEstimate,
                measuredFirstTurnInputsByAgent: measuredByAgent
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
            if let measured = budget.measuredFirstTurnInput {
                print("  Measured 1st-turn median: \(measured) input tokens")
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

    // MARK: - Helpers

    private static func fitCalibrations(
        sessions: [SessionRecord],
        workspace: Workspace,
        uncalibratedTokenizer: AgentTokenizerRegistry,
        probesByHash: [String: MCPProbeRecord],
        fallbackEstimate: MCPFallbackEstimate?,
        fileSystem: any ReadOnlyFileSystem,
        now: Date
    ) async throws -> [CalibrationRecord] {
        struct BudgetCacheKey: Hashable {
            var agent: AgentID
            var folderPath: String
            var modelKey: String
        }

        let budgetCapable = Set(workspace.budgetCapableAgents())
        var cachedBudgets: [BudgetCacheKey: Budget] = [:]
        var samples: [CalibrationSample] = []

        for session in sessions where budgetCapable.contains(session.agent) {
            guard let rawCwd = session.cwd,
                let firstTurn = session.firstTurnInput,
                firstTurn > 0
            else {
                continue
            }
            let folderURL = URL(fileURLWithPath: rawCwd).standardizedFileURL
            guard fileSystem.exists(folderURL) else {
                continue
            }

            let cacheKey = BudgetCacheKey(
                agent: session.agent,
                folderPath: folderURL.path,
                modelKey: session.model ?? ""
            )
            let predictedBudget: Budget
            if let hit = cachedBudgets[cacheKey] {
                predictedBudget = hit
            } else {
                guard
                    let computed = try? await workspace.budget(
                        for: session.agent,
                        folder: folderURL,
                        model: session.model,
                        tokenizer: uncalibratedTokenizer,
                        mcpProbesByConfigHash: probesByHash,
                        mcpFallbackEstimate: fallbackEstimate
                    )
                else {
                    continue
                }
                cachedBudgets[cacheKey] = computed
                predictedBudget = computed
            }

            let effectiveModel = predictedBudget.model ?? session.model ?? "*"
            let baseID = uncalibratedTokenizer.baseCounterID(for: session.agent, model: effectiveModel)
            let userMsgTokens = CalibrationFitter.estimateUserMessageTokens(
                charCount: session.firstUserMessageCharCount
            )
            samples.append(
                CalibrationSample(
                    agent: session.agent,
                    sessionID: session.sessionID,
                    model: effectiveModel,
                    tokenizerID: baseID,
                    predictedPrePromptTokens: predictedBudget.prePromptTokens,
                    measuredFirstTurnInput: firstTurn,
                    userMessageEstimatedTokens: userMsgTokens
                )
            )
        }

        guard !samples.isEmpty else { return [] }
        return CalibrationFitter().fit(samples: samples, now: now)
    }

    private static func parseCSVTokens(_ rawValues: [String]) -> Set<String> {
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

    private static func parseAPIProviders(_ rawValues: [String]) throws -> Set<TokenCountAPIProviderID> {
        var providers: Set<TokenCountAPIProviderID> = []
        for token in parseCSVTokens(rawValues) {
            guard let parsed = TokenCountAPIProviderID(rawValue: token.lowercased()) else {
                let valid = TokenCountAPIProviderID.allCases.map(\.rawValue).joined(separator: ", ")
                throw ValidationError("Unknown --api provider '\(token)'. Expected one of: \(valid).")
            }
            providers.insert(parsed)
        }
        return providers
    }

    private static func writeStderrWarning(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
    }
}
