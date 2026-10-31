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
        BuiltInBudgetCatalog.items(for: Self.id, displayName: displayName, model: model)
    }

    public func budgetContributions(for resolved: ResolvedArtifact, artifact: Artifact) -> [BudgetContribution] {
        AdapterBudgetContributor.contributions(for: resolved, artifact: artifact)
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
