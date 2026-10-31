import BentoCore
import Foundation

/// `AgentAdapter` implementation for OpenAI Codex CLI (`Docs/adapters/codex.md`).
public struct CodexAdapter: AgentAdapter, Sendable {
    public static let id: AgentID = .codex

    public var displayName: String {
        "Codex CLI"
    }

    public var capabilities: AgentCapabilities {
        [.inventory, .resolution, .budget, .usageLogs, .mcpProbe, .fixes]
    }

    public var paths: PathCatalog {
        CodexPathCatalog.catalog
    }

    /// Creates a Codex CLI adapter.
    public init() {}

    public func detect(in env: AgentEnvironment) async -> DetectionResult {
        let fs = env.fileSystem
        let candidates = [
            CodexPathCatalog.userCodexDirectory(in: env),
            CodexPathCatalog.managedDirectory(in: env)
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
        CodexDiscovery.discover(in: env, folder: folder)
    }

    public func resolve(_ artifacts: [Artifact], folder: URL, env: AgentEnvironment) -> Resolution {
        CodexResolver.resolve(artifacts, folder: folder, env: env)
    }

    public func builtInBudget(model: String?) -> [BudgetItem] {
        BuiltInBudgetCatalog.items(for: Self.id, displayName: displayName, model: model)
    }

    public func budgetContributions(for resolved: ResolvedArtifact, artifact: Artifact) -> [BudgetContribution] {
        AdapterBudgetContributor.contributions(for: resolved, artifact: artifact)
    }

    public func logSources(in env: AgentEnvironment) throws -> [LogSource] {
        let logsRoot = CodexPathCatalog.userLogsDirectory(in: env)
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
        CodexLogDecoder()
    }

    public func fixSupport() -> FixSupport {
        FixSupport(
            supportedKinds: [
                .disableMCPServer,
                .enableMCPServer,
                .disableSkill,
                .enableSkill,
                .consolidateSkillsViaSymlink,
                .trashArtifact
            ],
            supportsAtImports: false
        )
    }
}
