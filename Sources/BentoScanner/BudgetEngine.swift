import BentoAdapters
import BentoCore
import Foundation

/// Assembles per-agent pre-prompt and deferred context `Budget` breakdowns from precedence-resolved artifacts
/// (`PLAN.md` §4.1, §6.3, §6.4, §11 T09).
public struct BudgetEngine: Sendable {
    /// Creates a stateless budget computation engine.
    public init() {}

    /// Computes the context token `Budget` for `adapter` using `artifacts`, `resolution`, and `tokenizer`.
    public func computeBudget(
        adapter: any AgentAdapter,
        artifacts: [Artifact],
        resolution: Resolution,
        model: String? = nil,
        tokenizer: any TokenCountingProvider,
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

        var items = adapter.builtInBudget(model: effectiveModel)

        for resolved in resolution.ordered {
            guard let artifact = artifactsByID[resolved.artifactID] else {
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

        let contextWindow = tokenizer.contextWindow(for: agent, model: effectiveModel)
        return Budget(
            agent: agent,
            folder: resolution.folder,
            model: effectiveModel,
            items: items,
            measuredFirstTurnInput: measuredFirstTurnInput,
            contextWindow: contextWindow
        )
    }

    // MARK: - Private Helpers

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

    private static func resolveEffectiveModel(
        explicitModel: String?,
        resolution: Resolution,
        artifactsByID: [ArtifactID: Artifact]
    ) -> String? {
        if let trimmed = explicitModel?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            return trimmed
        }

        // Settings artifacts in `resolution.ordered` are ordered base -> override across all adapters.
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
