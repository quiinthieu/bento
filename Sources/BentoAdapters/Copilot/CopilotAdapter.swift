import BentoCore
import Foundation

/// `AgentAdapter` implementation for GitHub Copilot CLI (`Docs/adapters/copilot.md`).
public struct CopilotAdapter: AgentAdapter, Sendable {
    public static let id: AgentID = .copilot

    public var displayName: String {
        "Copilot CLI"
    }

    public var capabilities: AgentCapabilities {
        [.inventory, .resolution, .budget, .usageLogs, .mcpProbe, .fixes]
    }

    public var paths: PathCatalog {
        CopilotPathCatalog.catalog
    }

    /// Creates a GitHub Copilot CLI adapter.
    public init() {}

    public func detect(in env: AgentEnvironment) async -> DetectionResult {
        let userDir = CopilotPathCatalog.userCopilotDirectory(in: env)
        var detectedPaths: [String] = []
        if env.fileSystem.exists(userDir) {
            detectedPaths.append(userDir.standardizedFileURL.path)
        }

        return DetectionResult(
            isDetected: !detectedPaths.isEmpty,
            version: nil,
            detectedPaths: detectedPaths
        )
    }

    public func discover(in env: AgentEnvironment, folder: URL?) async throws -> [Artifact] {
        CopilotDiscovery.discover(in: env, folder: folder)
    }

    public func resolve(_ artifacts: [Artifact], folder: URL, env: AgentEnvironment) -> Resolution {
        CopilotResolver.resolve(artifacts, folder: folder, env: env)
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
            let countsPrePrompt: Bool =
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
                    countsTowardPrePrompt: countsPrePrompt
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
        let sessionStateRoot = CopilotPathCatalog.userSessionStateDirectory(in: env)
        let files = AdapterPathNormalizer.collectFilesRecursively(
            under: sessionStateRoot,
            fileSystem: env.fileSystem
        ) { url in
            CopilotPathCatalog.isSessionEventsLogFile(url)
        }

        return files.map { fileURL in
            let sessionDir = fileURL.deletingLastPathComponent().standardizedFileURL
            let inferredCwd = CopilotPayloadParser.parseWorkspaceCwd(in: sessionDir, env: env)
            return LogSource(
                agent: Self.id,
                url: fileURL,
                isCompressed: CopilotPathCatalog.isCompressedLogFile(fileURL),
                inferredCwd: inferredCwd
            )
        }
    }

    public func makeLogDecoder() -> any LogDecoder {
        CopilotLogDecoder()
    }

    public func fixSupport() -> FixSupport {
        FixSupport(
            supportedKinds: [.disableMCPServer, .enableMCPServer],
            supportsAtImports: false
        )
    }
}
