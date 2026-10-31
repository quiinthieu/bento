import BentoAdapters
import BentoCore
import BentoScanner
import BentoStore
import BentoTestSupport
import BentoTokenizer
import Foundation
import Testing

struct BudgetEngineTests {
    static let budgetAgents: [AgentID] = [.claudeCode, .codex, .gemini, .copilot]

    @Test("Built-in budget catalogs carry provenance and match bundled adapter copies byte-for-byte")
    func builtInBudgetResourcesCarryProvenanceAndMatchBundledCopies() throws {
        let repoRoot = FixtureHome.repositoryRoot()

        for agent in Self.budgetAgents {
            let rootURL = repoRoot.appendingPathComponent("Resources/builtins/\(agent.rawValue).json")
            let bundledURL = repoRoot.appendingPathComponent(
                "Sources/BentoAdapters/Resources/builtins/\(agent.rawValue).json"
            )

            let rootBytes = try Data(contentsOf: rootURL)
            let bundledBytes = try Data(contentsOf: bundledURL)
            #expect(rootBytes == bundledBytes, "Resources/builtins/\(agent.rawValue).json must match bundled copy")

            let doc = try BuiltInBudgetCatalog.document(for: agent)
            #expect(doc.agent == agent)
            #expect(!doc.measuredOn.isEmpty)
            #expect(!doc.agentVersion.isEmpty)
            #expect(!doc.defaultModel.isEmpty)
            #expect(!doc.sourceNote.isEmpty)
            #expect(doc.defaults.systemPromptTokens > 0)
            #expect(doc.defaults.builtInToolsTokens > 0)
            #expect(doc.defaults.uncertaintyFraction > 0 && doc.defaults.uncertaintyFraction < 1)
            #expect(!doc.models.isEmpty)
        }

        let adapters: [any AgentAdapter] = [
            ClaudeCodeAdapter(),
            CodexAdapter(),
            GeminiAdapter(),
            CopilotAdapter()
        ]
        for adapter in adapters {
            let items = adapter.builtInBudget(model: nil)
            #expect(items.count == 2)
            #expect(items.map(\.category) == [.builtInSystem, .builtInTools])
            for item in items {
                #expect(item.artifactID == nil)
                #expect(item.tokens > 0)
                #expect(item.confidence == .estimated)
                #expect(item.countsTowardPrePrompt)
                #expect(item.method.hasPrefix("estimated (built-in, measured on "))
                let range = try #require(item.range)
                #expect(range.contains(item.tokens))
            }
        }
    }

    @Test("Polyglot budget goldens pass for all 4 budget-capable agents and exclude deferred/onInvoke/conditional")
    func polyglotBudgetGoldensAndInvariants() async throws {
        let fixture = try FixtureHome(scenario: "polyglot")
        let env = fixture.makeEnvironment()
        let demoRepoURL = fixture.url.appendingPathComponent("repos/demo-app").standardizedFileURL
        let registry = try AgentTokenizerRegistry()
        let workspace = Workspace(environment: env)
        _ = try await workspace.scanFull()

        for agent in Self.budgetAgents {
            let budget = try await workspace.budget(
                for: agent,
                folder: demoRepoURL,
                model: nil,
                tokenizer: registry
            )

            #expect(budget.agent == agent)
            #expect(budget.folder == demoRepoURL.path)
            #expect(budget.contextWindow != nil)
            #expect(!budget.items.isEmpty)

            // Every item must carry confidence + non-empty method and valid range semantics.
            for item in budget.items {
                #expect(!item.label.isEmpty)
                #expect(!item.method.isEmpty, "Empty method on \(agent.rawValue) item '\(item.label)'")

                switch item.confidence {
                case .exact:
                    #expect(item.range == nil, "Exact item '\(item.label)' must not carry uncertainty range")
                case .estimated:
                    let range = try #require(item.range, "Estimated item '\(item.label)' must carry range")
                    #expect(range.contains(item.tokens))
                case .measured:
                    #expect(item.category == .hooks)
                    #expect(item.tokens == 0)
                    #expect(item.range == nil)
                    #expect(!item.countsTowardPrePrompt)
                }

                // Deferred / on-invoke / conditional items must NEVER count toward pre-prompt.
                switch item.category {
                case .builtInSystem, .builtInTools, .skillFrontmatter, .mcpToolsLoaded:
                    #expect(item.countsTowardPrePrompt, "Expected \(item.label) to count toward pre-prompt")
                case .skillBody, .mcpToolsDeferred, .commands, .hooks:
                    #expect(!item.countsTowardPrePrompt, "Expected \(item.label) to be excluded from pre-prompt")
                case .rules:
                    if item.label.contains("(conditional") {
                        #expect(!item.countsTowardPrePrompt, "Conditional rule '\(item.label)' must be excluded")
                    } else {
                        #expect(item.countsTowardPrePrompt, "Always-on rule '\(item.label)' must count")
                    }
                case .subagents:
                    if item.label.hasSuffix("(body)") {
                        #expect(!item.countsTowardPrePrompt, "Subagent body '\(item.label)' must be excluded")
                    } else {
                        #expect(item.countsTowardPrePrompt, "Subagent description '\(item.label)' must count")
                    }
                case .other:
                    break
                }
            }

            let manualPrePrompt = budget.items
                .filter(\.countsTowardPrePrompt)
                .reduce(0) { $0 + $1.tokens }
            let excludedTokens = budget.items
                .filter { !$0.countsTowardPrePrompt }
                .reduce(0) { $0 + $1.tokens }
            #expect(budget.prePromptTokens == manualPrePrompt)
            #expect(budget.prePromptTokens > 0)
            #expect(excludedTokens > 0, "Expected non-zero deferred/onInvoke/conditional tokens in \(agent.rawValue)")

            // Agent-specific category coverage checks on polyglot.
            let categories = Set(budget.items.map(\.category))
            #expect(categories.contains(.builtInSystem))
            #expect(categories.contains(.builtInTools))
            #expect(categories.contains(.rules))
            #expect(categories.contains(.skillFrontmatter))
            #expect(categories.contains(.skillBody))
            #expect(categories.contains(.mcpToolsLoaded))
            #expect(categories.contains(.hooks))
            #expect(budget.items.contains { $0.category == .rules && $0.label.contains("(conditional:") })

            switch agent {
            case .claudeCode:
                #expect(categories.contains(.mcpToolsDeferred))
                #expect(categories.contains(.subagents))
                #expect(categories.contains(.commands))
                #expect(budget.items.contains { $0.label == "github (tool-search stub)" && $0.countsTowardPrePrompt })
                #expect(budget.items.contains { $0.label == "github (deferred tools)" && !$0.countsTowardPrePrompt })

            case .codex:
                #expect(budget.model == "gpt-5-codex")
                #expect(budget.contextWindow == 400_000)
                let ruleItems = budget.items.filter { $0.category == .rules }
                #expect(ruleItems.allSatisfy { $0.confidence == .exact && $0.method == "o200k_base" })

            case .gemini, .copilot:
                #expect(categories.contains(.subagents))
                #expect(categories.contains(.commands))

            case .cursor, .windsurf:
                break
            }

            let goldenURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("__golden__/polyglot-budget-\(agent.rawValue).json")
            try GoldenFile.assertMatches(budget, goldenURL: goldenURL, homeURL: fixture.url)
        }
    }

    @Test("Cursor and Windsurf reject budget computation with BentoScannerError.budgetUnsupported")
    func cursorAndWindsurfThrowBudgetUnsupported() async throws {
        let fixture = try FixtureHome(scenario: "polyglot")
        let demoRepoURL = fixture.url.appendingPathComponent("repos/demo-app").standardizedFileURL
        let registry = try AgentTokenizerRegistry()
        let workspace = Workspace(environment: fixture.makeEnvironment())

        await #expect(throws: BentoScannerError.budgetUnsupported(.cursor)) {
            try await workspace.budget(for: .cursor, folder: demoRepoURL, model: nil, tokenizer: registry)
        }
        await #expect(throws: BentoScannerError.budgetUnsupported(.windsurf)) {
            try await workspace.budget(for: .windsurf, folder: demoRepoURL, model: nil, tokenizer: registry)
        }
    }

    @Test("BentoStore persists and round-trips budget_item rows idempotently per snapshot, repo, and agent")
    func storePersistsAndRoundTripsBudgetItems() async throws {
        let fixture = try FixtureHome(scenario: "polyglot")
        let demoRepoURL = fixture.url.appendingPathComponent("repos/demo-app").standardizedFileURL
        let store = try BentoStore.inMemory()
        let registry = try AgentTokenizerRegistry()
        let workspace = Workspace(environment: fixture.makeEnvironment(), store: store)

        let snapshot = try await workspace.scanFull()
        let budgets = try await workspace.budgets(folder: demoRepoURL, model: nil, tokenizer: registry)
        #expect(budgets.map(\.agent) == Self.budgetAgents)

        for budget in budgets {
            try store.saveBudget(budget, snapshotID: snapshot.id)
            // Saving a second time must replace prior rows rather than duplicating them.
            try store.saveBudget(budget, snapshotID: snapshot.id)

            let persisted = try store.fetchBudgetItems(
                snapshotID: snapshot.id,
                repoPath: demoRepoURL.path,
                agent: budget.agent
            )
            #expect(persisted == budget.items)
        }
    }
}
