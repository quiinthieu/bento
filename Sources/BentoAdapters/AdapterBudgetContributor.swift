import BentoCore
import Foundation

/// Shared `BudgetContribution` mapper across budget-capable adapters (`PLAN.md` §5.1, §6.3, §6.4, §11 T09).
enum AdapterBudgetContributor {
    /// Default fallback token estimate for an unprobed MCP server's full tool schemas.
    static let defaultUnprobedMCPTokens = 1_200

    /// Always-loaded tool-search stub overhead when an MCP server's tools are deferred (`PLAN.md` §6.4).
    static let deferredMCPToolSearchStubTokens = 120

    static func contributions(for resolved: ResolvedArtifact, artifact: Artifact) -> [BudgetContribution] {
        guard resolved.effectiveLoadMode != .never else {
            return []
        }

        switch artifact.payload {
        case .rules(let doc):
            switch resolved.effectiveLoadMode {
            case .always:
                return [
                    BudgetContribution(
                        artifactID: artifact.id,
                        category: .rules,
                        label: artifact.name,
                        text: doc.content,
                        countsTowardPrePrompt: true
                    )
                ]

            case .conditional(let globs):
                let label =
                    globs.isEmpty
                    ? "\(artifact.name) (conditional)"
                    : "\(artifact.name) (conditional: \(globs.joined(separator: ", ")))"
                return [
                    BudgetContribution(
                        artifactID: artifact.id,
                        category: .rules,
                        label: label,
                        text: doc.content,
                        countsTowardPrePrompt: false
                    )
                ]

            case .onInvoke, .deferred, .frontmatterOnly, .never:
                return [
                    BudgetContribution(
                        artifactID: artifact.id,
                        category: .rules,
                        label: "\(artifact.name) (conditional)",
                        text: doc.content,
                        countsTowardPrePrompt: false
                    )
                ]
            }

        case .skill(let doc):
            var items: [BudgetContribution] = []
            let summaryText = [doc.name, doc.description].compactMap { $0 }.joined(separator: ": ")
            if resolved.effectiveLoadMode == .frontmatterOnly || resolved.effectiveLoadMode == .always {
                items.append(
                    BudgetContribution(
                        artifactID: artifact.id,
                        category: .skillFrontmatter,
                        label: "\(doc.name) (frontmatter)",
                        text: summaryText,
                        countsTowardPrePrompt: true
                    )
                )
            }
            items.append(
                BudgetContribution(
                    artifactID: artifact.id,
                    category: .skillBody,
                    label: "\(doc.name) (body)",
                    text: doc.body,
                    countsTowardPrePrompt: false
                )
            )
            return items

        case .subagent(let doc):
            var items: [BudgetContribution] = []
            let summaryText = [doc.name, doc.description].compactMap { $0 }.joined(separator: ": ")
            let countsDescription =
                resolved.effectiveLoadMode == .frontmatterOnly || resolved.effectiveLoadMode == .always
            items.append(
                BudgetContribution(
                    artifactID: artifact.id,
                    category: .subagents,
                    label: "\(doc.name) (description)",
                    text: summaryText,
                    countsTowardPrePrompt: countsDescription
                )
            )
            if !doc.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items.append(
                    BudgetContribution(
                        artifactID: artifact.id,
                        category: .subagents,
                        label: "\(doc.name) (body)",
                        text: doc.body,
                        countsTowardPrePrompt: false
                    )
                )
            }
            return items

        case .command(let doc):
            return [
                BudgetContribution(
                    artifactID: artifact.id,
                    category: .commands,
                    label: doc.name,
                    text: doc.body,
                    countsTowardPrePrompt: false
                )
            ]

        case .hook:
            // Hook commands run externally; dynamic stdout may inject context at runtime (measured-only, PLAN §5.2).
            return [
                BudgetContribution(
                    artifactID: artifact.id,
                    category: .hooks,
                    label: artifact.name,
                    text: nil,
                    fixedTokensEstimate: 0,
                    countsTowardPrePrompt: false
                )
            ]

        case .mcpServer:
            if resolved.effectiveLoadMode == .deferred {
                return [
                    BudgetContribution(
                        artifactID: artifact.id,
                        category: .mcpToolsLoaded,
                        label: "\(artifact.name) (tool-search stub)",
                        fixedTokensEstimate: deferredMCPToolSearchStubTokens,
                        countsTowardPrePrompt: true
                    ),
                    BudgetContribution(
                        artifactID: artifact.id,
                        category: .mcpToolsDeferred,
                        label: "\(artifact.name) (deferred tools)",
                        fixedTokensEstimate: defaultUnprobedMCPTokens,
                        countsTowardPrePrompt: false
                    )
                ]
            }
            return [
                BudgetContribution(
                    artifactID: artifact.id,
                    category: .mcpToolsLoaded,
                    label: artifact.name,
                    fixedTokensEstimate: defaultUnprobedMCPTokens,
                    countsTowardPrePrompt: true
                )
            ]

        case .settings, .plugin, .other:
            return []
        }
    }
}
