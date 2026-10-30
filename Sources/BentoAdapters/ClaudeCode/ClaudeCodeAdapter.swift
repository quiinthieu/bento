import BentoCore
import Foundation

/// `AgentAdapter` implementation for Anthropic Claude Code (`Docs/adapters/claude-code.md`).
public struct ClaudeCodeAdapter: AgentAdapter, Sendable {
    public static let id: AgentID = .claudeCode

    public var displayName: String {
        "Claude Code"
    }

    public var capabilities: AgentCapabilities {
        [.inventory, .resolution, .budget, .usageLogs, .mcpProbe, .fixes]
    }

    public var paths: PathCatalog {
        ClaudeCodePathCatalog.catalog
    }

    /// Creates a Claude Code adapter.
    public init() {}

    public func detect(in env: AgentEnvironment) async -> DetectionResult {
        let fs = env.fileSystem
        let candidates = [
            ClaudeCodePathCatalog.userConfigDirectory(in: env),
            ClaudeCodePathCatalog.userStateFile(in: env),
            ClaudeCodePathCatalog.managedDirectory(in: env)
        ]

        var detectedPaths: [String] = []
        for candidate in candidates where fs.exists(candidate) {
            let path = candidate.standardizedFileURL.path
            if !detectedPaths.contains(path) {
                detectedPaths.append(path)
            }
        }

        return DetectionResult(
            isDetected: !detectedPaths.isEmpty,
            version: nil,
            detectedPaths: detectedPaths
        )
    }

    public func discover(in env: AgentEnvironment, folder: URL?) async throws -> [Artifact] {
        ClaudeCodeDiscovery.discover(in: env, folder: folder)
    }

    public func resolve(_ artifacts: [Artifact], folder: URL, env: AgentEnvironment) -> Resolution {
        ClaudeCodeResolver.resolve(artifacts, folder: folder, env: env)
    }

    public func builtInBudget(model: String?) -> [BudgetItem] {
        []
    }

    public func budgetContributions(for resolved: ResolvedArtifact, artifact: Artifact) -> [BudgetContribution] {
        guard resolved.effectiveLoadMode != .never else {
            return []
        }

        switch artifact.payload {
        case .rules(let doc):
            let prePrompt: Bool =
                switch resolved.effectiveLoadMode {
                case .always:
                    true
                case .conditional, .onInvoke, .deferred, .frontmatterOnly, .never:
                    false
                }
            return [
                BudgetContribution(
                    artifactID: artifact.id,
                    category: .rules,
                    label: artifact.name,
                    text: doc.content,
                    countsTowardPrePrompt: prePrompt
                )
            ]

        case .skill(let doc):
            var items: [BudgetContribution] = []
            let summaryText = [doc.name, doc.description].compactMap { $0 }.joined(separator: ": ")
            if resolved.effectiveLoadMode == .frontmatterOnly {
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
            let summaryText = [doc.name, doc.description].compactMap { $0 }.joined(separator: ": ")
            return [
                BudgetContribution(
                    artifactID: artifact.id,
                    category: .subagents,
                    label: doc.name,
                    text: summaryText,
                    countsTowardPrePrompt: resolved.effectiveLoadMode == .frontmatterOnly
                )
            ]

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

        case .hook(let config):
            return [
                BudgetContribution(
                    artifactID: artifact.id,
                    category: .hooks,
                    label: artifact.name,
                    text: config.command,
                    countsTowardPrePrompt: false
                )
            ]

        case .mcpServer:
            let isDeferred = resolved.effectiveLoadMode == .deferred
            return [
                BudgetContribution(
                    artifactID: artifact.id,
                    category: isDeferred ? .mcpToolsDeferred : .mcpToolsLoaded,
                    label: artifact.name,
                    fixedTokensEstimate: isDeferred ? 120 : 1_200,
                    countsTowardPrePrompt: true
                )
            ]

        case .settings, .plugin, .other:
            return []
        }
    }

    public func logSources(in env: AgentEnvironment) throws -> [LogSource] {
        let logsRoot = ClaudeCodePathCatalog.userLogsDirectory(in: env)
        let files = AdapterPathNormalizer.collectFilesRecursively(under: logsRoot, fileSystem: env.fileSystem) { url in
            let lower = url.path.lowercased()
            return lower.hasSuffix(".jsonl") || lower.hasSuffix(".jsonl.zst")
        }

        return files.map { fileURL in
            LogSource(
                agent: Self.id,
                url: fileURL,
                isCompressed: fileURL.path.lowercased().hasSuffix(".zst"),
                inferredCwd: nil
            )
        }
    }

    public func makeLogDecoder() -> any LogDecoder {
        ClaudeCodeLogDecoder()
    }

    public func fixSupport() -> FixSupport {
        FixSupport(
            supportedKinds: [
                .disableMCPServer,
                .enableMCPServer,
                .disableSkill,
                .enableSkill,
                .consolidateSkillsViaSymlink,
                .replaceDuplicateRulesWithImport,
                .trashArtifact
            ],
            supportsAtImports: true
        )
    }
}
