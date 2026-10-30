import BentoCore
import Foundation

/// `AgentAdapter` implementation for Windsurf (`Docs/adapters/windsurf.md`).
/// Scoped to inventory and rules/precedence resolution in v1 (`PLAN.md` §1, §5.2, §11).
public struct WindsurfAdapter: AgentAdapter, Sendable {
    public static let id: AgentID = .windsurf

    public var displayName: String {
        "Windsurf"
    }

    public var capabilities: AgentCapabilities {
        [.inventory, .resolution]
    }

    public var paths: PathCatalog {
        WindsurfPathCatalog.catalog
    }

    /// Creates a Windsurf adapter.
    public init() {}

    public func detect(in env: AgentEnvironment) async -> DetectionResult {
        let fs = env.fileSystem
        let candidates = [
            WindsurfPathCatalog.userWindsurfDirectory(in: env),
            WindsurfPathCatalog.managedRulesDirectory(in: env)
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
        WindsurfDiscovery.discover(in: env, folder: folder)
    }

    public func resolve(_ artifacts: [Artifact], folder: URL, env: AgentEnvironment) -> Resolution {
        WindsurfResolver.resolve(artifacts, folder: folder, env: env)
    }

    public func builtInBudget(model: String?) -> [BudgetItem] {
        []
    }

    public func budgetContributions(for resolved: ResolvedArtifact, artifact: Artifact) -> [BudgetContribution] {
        []
    }

    public func logSources(in env: AgentEnvironment) throws -> [LogSource] {
        []
    }

    public func makeLogDecoder() -> any LogDecoder {
        WindsurfLogDecoder()
    }

    public func fixSupport() -> FixSupport {
        FixSupport()
    }
}
