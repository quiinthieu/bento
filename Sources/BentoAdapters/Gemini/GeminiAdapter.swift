import BentoCore
import Foundation

/// `AgentAdapter` implementation for Google Gemini CLI (`Docs/adapters/gemini.md`).
public struct GeminiAdapter: AgentAdapter, Sendable {
    public static let id: AgentID = .gemini

    public var displayName: String {
        "Gemini CLI"
    }

    public var capabilities: AgentCapabilities {
        [.inventory, .resolution, .budget, .usageLogs, .mcpProbe, .fixes]
    }

    public var paths: PathCatalog {
        GeminiPathCatalog.catalog
    }

    /// Creates a Gemini CLI adapter.
    public init() {}

    public func detect(in env: AgentEnvironment) async -> DetectionResult {
        let fs = env.fileSystem
        let candidates = [
            GeminiPathCatalog.userGeminiDirectory(in: env),
            GeminiPathCatalog.managedSettingsFile(in: env),
            GeminiPathCatalog.systemDefaultsFile(in: env)
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
        GeminiDiscovery.discover(in: env, folder: folder)
    }

    public func resolve(_ artifacts: [Artifact], folder: URL, env: AgentEnvironment) -> Resolution {
        GeminiResolver.resolve(artifacts, folder: folder, env: env)
    }

    public func builtInBudget(model: String?) -> [BudgetItem] {
        BuiltInBudgetCatalog.items(for: Self.id, displayName: displayName, model: model)
    }

    public func budgetContributions(for resolved: ResolvedArtifact, artifact: Artifact) -> [BudgetContribution] {
        AdapterBudgetContributor.contributions(for: resolved, artifact: artifact)
    }

    public func logSources(in env: AgentEnvironment) throws -> [LogSource] {
        let logsRoot = GeminiPathCatalog.userLogsRootDirectory(in: env)
        let files = AdapterPathNormalizer.collectFilesRecursively(
            under: logsRoot,
            fileSystem: env.fileSystem
        ) { url in
            GeminiPathCatalog.isSessionLogFile(url)
        }

        return files.map { fileURL in
            LogSource(
                agent: Self.id,
                url: fileURL,
                isCompressed: GeminiPathCatalog.isCompressedLogFile(fileURL),
                inferredCwd: nil
            )
        }
    }

    public func makeLogDecoder() -> any LogDecoder {
        GeminiLogDecoder()
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
