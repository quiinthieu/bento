import BentoAdapters
import BentoCore
import Foundation

/// Assembles per-agent pre-prompt and deferred context `Budget` breakdowns from precedence-resolved artifacts
/// (`PLAN.md` §4.1, §6.3, §6.4, §11 T09–T10).
public struct BudgetEngine: Sendable {
    private static let defaultUnprobedMCPTokens = 1_200
    private static let deferredMCPToolSearchStubTokens = 120
    private static let defaultClaudeAutoDeferFraction = 0.10

    private enum ClaudeToolSearchPolicy {
        case forced
        case disabled
        case auto(thresholdFraction: Double)
    }

    private struct EvaluatedMCPServer {
        var tokens: Int
        var range: ClosedRange<Int>
        var method: String
        var explicitlyDeferred: Bool
    }

    /// Creates a stateless budget computation engine.
    public init() {}

    /// Computes the context token `Budget` for `adapter` using `artifacts`, `resolution`, `tokenizer`,
    /// optional cached `mcpProbesByConfigHash`, and optional historical `mcpFallbackEstimate`.
    public func computeBudget(
        adapter: any AgentAdapter,
        artifacts: [Artifact],
        resolution: Resolution,
        model: String? = nil,
        tokenizer: any TokenCountingProvider,
        mcpProbesByConfigHash: [String: MCPProbeRecord] = [:],
        mcpFallbackEstimate: MCPFallbackEstimate? = nil,
        environment: [String: String] = [:],
        measuredFirstTurnInput: Int? = nil
    ) throws -> Budget {
        let agent = type(of: adapter).id
        guard adapter.capabilities.contains(.budget) else {
            throw BentoScannerError.budgetUnsupported(agent)
        }

        var artifactsByID: [ArtifactID: Artifact] = [:]
        artifactsByID.reserveCapacity(artifacts.count)
        for artifact in artifacts {
            artifactsByID[artifact.id] = artifact
        }

        let effectiveModel = Self.resolveEffectiveModel(
            explicitModel: model,
            resolution: resolution,
            artifactsByID: artifactsByID
        )
        let contextWindow = tokenizer.contextWindow(for: agent, model: effectiveModel)

        // Pre-evaluate active MCP servers so adapter-level auto-defer thresholds (e.g. Claude ENABLE_TOOL_SEARCH)
        // can inspect aggregate MCP tool schema tokens across the repository resolution.
        var evaluatedMCPByArtifactID: [ArtifactID: EvaluatedMCPServer] = [:]
        for resolved in resolution.ordered where resolved.effectiveLoadMode != .never {
            guard let artifact = artifactsByID[resolved.artifactID],
                case .mcpServer(let mcpConfig) = artifact.payload
            else {
                continue
            }
            evaluatedMCPByArtifactID[artifact.id] = evaluateMCPServer(
                config: mcpConfig,
                explicitlyDeferred: resolved.effectiveLoadMode == .deferred,
                agent: agent,
                model: effectiveModel,
                tokenizer: tokenizer,
                mcpProbesByConfigHash: mcpProbesByConfigHash,
                mcpFallbackEstimate: mcpFallbackEstimate
            )
        }

        let claudeAutoDeferTriggered: Bool
        let claudeForceDisableDefer: Bool
        if agent == .claudeCode {
            let policy = Self.resolveClaudeToolSearchPolicy(
                resolution: resolution,
                artifactsByID: artifactsByID,
                environment: environment
            )
            switch policy {
            case .forced:
                claudeAutoDeferTriggered = true
                claudeForceDisableDefer = false
            case .disabled:
                claudeAutoDeferTriggered = false
                claudeForceDisableDefer = true
            case .auto(let fraction):
                claudeForceDisableDefer = false
                if let window = contextWindow, window > 0 {
                    let thresholdTokens = max(1, Int((Double(window) * fraction).rounded()))
                    let nonDeferredSum = evaluatedMCPByArtifactID.values
                        .filter { !$0.explicitlyDeferred }
                        .reduce(0) { $0 + $1.tokens }
                    claudeAutoDeferTriggered = nonDeferredSum >= thresholdTokens
                } else {
                    claudeAutoDeferTriggered = false
                }
            }
        } else {
            claudeAutoDeferTriggered = false
            claudeForceDisableDefer = false
        }

        var items = adapter.builtInBudget(model: effectiveModel)

        for resolved in resolution.ordered {
            guard let artifact = artifactsByID[resolved.artifactID] else {
                continue
            }

            if resolved.effectiveLoadMode != .never,
                case .mcpServer = artifact.payload,
                let evaluated = evaluatedMCPByArtifactID[artifact.id]
            {
                let shouldDefer: Bool
                if claudeForceDisableDefer {
                    shouldDefer = false
                } else {
                    shouldDefer = evaluated.explicitlyDeferred || claudeAutoDeferTriggered
                }
                items.append(
                    contentsOf: Self.materializeMCPItems(
                        artifact: artifact,
                        evaluated: evaluated,
                        deferred: shouldDefer
                    )
                )
                continue
            }

            let contributions = adapter.budgetContributions(for: resolved, artifact: artifact)
            for (index, contribution) in contributions.enumerated() {
                items.append(
                    materializeItem(
                        from: contribution,
                        artifact: artifact,
                        contributionIndex: index,
                        agent: agent,
                        model: effectiveModel,
                        tokenizer: tokenizer
                    )
                )
            }
        }

        return Budget(
            agent: agent,
            folder: resolution.folder,
            model: effectiveModel,
            items: items,
            measuredFirstTurnInput: measuredFirstTurnInput,
            contextWindow: contextWindow
        )
    }

    // MARK: - MCP Server Evaluation

    private func evaluateMCPServer(
        config: MCPServerConfig,
        explicitlyDeferred: Bool,
        agent: AgentID,
        model: String?,
        tokenizer: any TokenCountingProvider,
        mcpProbesByConfigHash: [String: MCPProbeRecord],
        mcpFallbackEstimate: MCPFallbackEstimate?
    ) -> EvaluatedMCPServer {
        let configHash = MCPServerConfigHasher.hash(config)

        if let probe = mcpProbesByConfigHash[configHash], probe.ok {
            let activeTools = probe.activeTools(for: config)
            var totalTokens = 0
            var counterMethod: String?

            for tool in activeTools {
                let json = tool.canonicalSerializationJSON()
                let cacheKey = "mcp-budget:\(configHash):\(tool.name):\(ContentHasher.sha256Hex(Data(json.utf8)))"
                let estimate = tokenizer.estimateTokens(
                    text: json,
                    contentHash: cacheKey,
                    agent: agent,
                    model: model
                )
                totalTokens += estimate.tokens
                if counterMethod == nil {
                    counterMethod = estimate.method
                }
            }

            let baseMethod =
                counterMethod
                ?? tokenizer.estimateTokens(text: "{}", contentHash: nil, agent: agent, model: model).method
            let toolWord = activeTools.count == 1 ? "tool" : "tools"
            let lo = max(0, Int((Double(totalTokens) * 0.88).rounded(.down)))
            let hi = max(lo, Int((Double(totalTokens) * 1.12).rounded(.up)))

            return EvaluatedMCPServer(
                tokens: totalTokens,
                range: lo...hi,
                method: "probed (\(activeTools.count) \(toolWord), \(baseMethod))",
                explicitlyDeferred: explicitlyDeferred
            )
        }

        if let fallback = mcpFallbackEstimate, fallback.sampleServerCount > 0 {
            let fallbackTokens = max(0, fallback.estimatedServerTokens(for: config))
            let lo = max(0, Int((Double(fallbackTokens) * 0.5).rounded(.down)))
            let hi = max(lo, Int((Double(fallbackTokens) * 1.8).rounded(.up)))
            let serverWord = fallback.sampleServerCount == 1 ? "server" : "servers"
            return EvaluatedMCPServer(
                tokens: fallbackTokens,
                range: lo...hi,
                method: "unknown (not probed; median fallback from \(fallback.sampleServerCount) probed \(serverWord))",
                explicitlyDeferred: explicitlyDeferred
            )
        }

        let defaultTokens = Self.defaultUnprobedMCPTokens
        let lo = max(0, Int((Double(defaultTokens) * 0.5).rounded(.down)))
        let hi = max(lo, Int((Double(defaultTokens) * 1.8).rounded(.up)))
        return EvaluatedMCPServer(
            tokens: defaultTokens,
            range: lo...hi,
            method: "unknown (not probed; default fallback estimate)",
            explicitlyDeferred: explicitlyDeferred
        )
    }

    private static func materializeMCPItems(
        artifact: Artifact,
        evaluated: EvaluatedMCPServer,
        deferred: Bool
    ) -> [BudgetItem] {
        if deferred {
            let stubTokens = deferredMCPToolSearchStubTokens
            let stubLo = max(0, Int((Double(stubTokens) * 0.75).rounded(.down)))
            let stubHi = max(stubLo, Int((Double(stubTokens) * 1.25).rounded(.up)))
            return [
                BudgetItem(
                    artifactID: artifact.id,
                    category: .mcpToolsLoaded,
                    label: "\(artifact.name) (tool-search stub)",
                    tokens: stubTokens,
                    range: stubLo...stubHi,
                    confidence: .estimated,
                    method: "estimated (deferred MCP tool-search stub)",
                    countsTowardPrePrompt: true
                ),
                BudgetItem(
                    artifactID: artifact.id,
                    category: .mcpToolsDeferred,
                    label: "\(artifact.name) (deferred tools)",
                    tokens: evaluated.tokens,
                    range: evaluated.range,
                    confidence: .estimated,
                    method: evaluated.method,
                    countsTowardPrePrompt: false
                )
            ]
        }

        return [
            BudgetItem(
                artifactID: artifact.id,
                category: .mcpToolsLoaded,
                label: artifact.name,
                tokens: evaluated.tokens,
                range: evaluated.range,
                confidence: .estimated,
                method: evaluated.method,
                countsTowardPrePrompt: true
            )
        ]
    }

    // MARK: - Contribution Materialization

    private func materializeItem(
        from contribution: BudgetContribution,
        artifact: Artifact,
        contributionIndex: Int,
        agent: AgentID,
        model: String?,
        tokenizer: any TokenCountingProvider
    ) -> BudgetItem {
        // Dynamic hook stdout is measured-only at runtime, never statically tokenized (PLAN §5.2).
        if contribution.category == .hooks
            && contribution.text == nil
            && (contribution.fixedTokensEstimate ?? 0) == 0
        {
            return BudgetItem(
                artifactID: contribution.artifactID,
                category: .hooks,
                label: contribution.label,
                tokens: 0,
                range: nil,
                confidence: .measured,
                method: "measured-only (dynamic hook output)",
                countsTowardPrePrompt: false
            )
        }

        if let text = contribution.text {
            let cacheKey = "\(artifact.contentHash):\(contribution.category.rawValue):\(contributionIndex)"
            let estimate = tokenizer.estimateTokens(
                text: text,
                contentHash: cacheKey,
                agent: agent,
                model: model
            )
            return BudgetItem(
                artifactID: contribution.artifactID,
                category: contribution.category,
                label: contribution.label,
                tokens: estimate.tokens,
                range: estimate.range,
                confidence: estimate.confidence,
                method: estimate.method,
                countsTowardPrePrompt: contribution.countsTowardPrePrompt
            )
        }

        let estimatedTokens = max(0, contribution.fixedTokensEstimate ?? 0)
        if contribution.category == .mcpToolsLoaded || contribution.category == .mcpToolsDeferred {
            let isToolSearchStub =
                contribution.category == .mcpToolsLoaded
                && contribution.countsTowardPrePrompt
                && contribution.label.contains("stub")
            if isToolSearchStub {
                let lo = max(0, Int((Double(estimatedTokens) * 0.75).rounded(.down)))
                let hi = max(lo, Int((Double(estimatedTokens) * 1.25).rounded(.up)))
                return BudgetItem(
                    artifactID: contribution.artifactID,
                    category: contribution.category,
                    label: contribution.label,
                    tokens: estimatedTokens,
                    range: lo...hi,
                    confidence: .estimated,
                    method: "estimated (deferred MCP tool-search stub)",
                    countsTowardPrePrompt: contribution.countsTowardPrePrompt
                )
            }

            let lo = max(0, Int((Double(estimatedTokens) * 0.5).rounded(.down)))
            let hi = max(lo, Int((Double(estimatedTokens) * 1.8).rounded(.up)))
            return BudgetItem(
                artifactID: contribution.artifactID,
                category: contribution.category,
                label: contribution.label,
                tokens: estimatedTokens,
                range: lo...hi,
                confidence: .estimated,
                method: "unknown (not probed; default fallback estimate)",
                countsTowardPrePrompt: contribution.countsTowardPrePrompt
            )
        }

        let lo = max(0, Int((Double(estimatedTokens) * 0.85).rounded(.down)))
        let hi = max(lo, Int((Double(estimatedTokens) * 1.15).rounded(.up)))
        return BudgetItem(
            artifactID: contribution.artifactID,
            category: contribution.category,
            label: contribution.label,
            tokens: estimatedTokens,
            range: lo...hi,
            confidence: .estimated,
            method: "estimated (fixed fallback)",
            countsTowardPrePrompt: contribution.countsTowardPrePrompt
        )
    }

    // MARK: - Settings & Policy Helpers

    private static func resolveClaudeToolSearchPolicy(
        resolution: Resolution,
        artifactsByID: [ArtifactID: Artifact],
        environment: [String: String]
    ) -> ClaudeToolSearchPolicy {
        var rawDirective: String?

        for resolved in resolution.ordered {
            guard let artifact = artifactsByID[resolved.artifactID],
                artifact.enabled,
                case .settings(let doc) = artifact.payload
            else {
                continue
            }
            if case .bool(let flag) = doc.tree["enableToolSearch"] {
                rawDirective = flag ? "true" : "false"
            }
            if case .string(let str) = doc.tree["enableToolSearch"] {
                rawDirective = str
            }
            if case .object(let envObj) = doc.tree["env"],
                case .string(let envVal) = envObj["ENABLE_TOOL_SEARCH"]
            {
                rawDirective = envVal
            }
        }

        if let envOverride = environment["ENABLE_TOOL_SEARCH"],
            !envOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            rawDirective = envOverride
        }

        guard let normalized = rawDirective?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !normalized.isEmpty
        else {
            return .auto(thresholdFraction: defaultClaudeAutoDeferFraction)
        }

        if normalized == "true" || normalized == "1" {
            return .forced
        }
        if normalized == "false" || normalized == "0" {
            return .disabled
        }
        if normalized == "auto" {
            return .auto(thresholdFraction: defaultClaudeAutoDeferFraction)
        }
        if normalized.hasPrefix("auto:"),
            let pct = Double(normalized.dropFirst("auto:".count)),
            pct > 0,
            pct <= 100
        {
            return .auto(thresholdFraction: pct / 100.0)
        }

        return .auto(thresholdFraction: defaultClaudeAutoDeferFraction)
    }

    private static func resolveEffectiveModel(
        explicitModel: String?,
        resolution: Resolution,
        artifactsByID: [ArtifactID: Artifact]
    ) -> String? {
        if let trimmed = explicitModel?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            return trimmed
        }

        var configuredModel: String?
        for resolved in resolution.ordered {
            guard let artifact = artifactsByID[resolved.artifactID],
                artifact.enabled,
                case .settings(let doc) = artifact.payload
            else {
                continue
            }
            if let extracted = extractModelName(from: doc.tree) {
                configuredModel = extracted
            }
        }
        return configuredModel
    }

    private static func extractModelName(from tree: [String: JSONValue]) -> String? {
        switch tree["model"] {
        case .string(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .object(let dict):
            if case .string(let nested) = dict["name"] {
                let trimmed = nested.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        default:
            return nil
        }
    }
}
