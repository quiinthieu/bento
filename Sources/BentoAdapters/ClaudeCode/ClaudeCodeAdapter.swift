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
        BuiltInBudgetCatalog.items(for: Self.id, displayName: displayName, model: model)
    }

    public func budgetContributions(for resolved: ResolvedArtifact, artifact: Artifact) -> [BudgetContribution] {
        AdapterBudgetContributor.contributions(for: resolved, artifact: artifact)
    }

    public func logSources(in env: AgentEnvironment) throws -> [LogSource] {
        let logsRoot = ClaudeCodePathCatalog.userLogsDirectory(in: env)
        let homePath = env.home.standardizedFileURL.path
        let files = AdapterPathNormalizer.collectFilesRecursively(under: logsRoot, fileSystem: env.fileSystem) { url in
            let lower = url.path.lowercased()
            return lower.hasSuffix(".jsonl") || lower.hasSuffix(".jsonl.zst")
        }

        var decodedDirCache: [String: String?] = [:]
        return files.map { fileURL in
            let encodedFolder = fileURL.deletingLastPathComponent().lastPathComponent
            let inferredCwd: String?
            if let cached = decodedDirCache[encodedFolder] {
                inferredCwd = cached
            } else {
                let resolved = RepoDiscovery.decodeClaudeEncodedProjectDirName(encodedFolder, in: env)?.path
                decodedDirCache[encodedFolder] = resolved
                inferredCwd = resolved
            }
            return LogSource(
                agent: Self.id,
                url: fileURL,
                isCompressed: fileURL.path.lowercased().hasSuffix(".zst"),
                inferredCwd: inferredCwd,
                homePath: homePath
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
