import ArgumentParser
import BentoCore
import BentoScanner
import BentoStore
import BentoTokenizer
import Foundation

/// Computes per-agent context token budgets (built-ins, rules, skills, subagents, commands, hooks, MCP tools)
/// for a target repository (`PLAN.md` §6.8, §11 T09).
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

    mutating func run() async throws {
        let parsedAgent = try agent.map { try CLICommonOptions.parseAgent($0) }
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveModelOverride = (trimmedModel?.isEmpty == false) ? trimmedModel : nil
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

        let budgets: [Budget]
        if let parsedAgent {
            let single = try await workspace.budget(
                for: parsedAgent,
                folder: targetURL,
                model: effectiveModelOverride,
                tokenizer: tokenizer
            )
            budgets = [single]
        } else {
            budgets = try await workspace.budgets(
                folder: targetURL,
                model: effectiveModelOverride,
                tokenizer: tokenizer
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
}
