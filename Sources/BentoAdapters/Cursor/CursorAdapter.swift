import BentoCore
import Foundation

/// `AgentAdapter` implementation for Cursor (`Docs/adapters/cursor.md`).
/// Scoped to inventory and rules/precedence resolution in v1 (`PLAN.md` §1, §5.2, §11).
public struct CursorAdapter: AgentAdapter, Sendable {
    public static let id: AgentID = .cursor

    public var displayName: String {
        "Cursor"
    }

    public var capabilities: AgentCapabilities {
        [.inventory, .resolution]
    }

    public var paths: PathCatalog {
        CursorPathCatalog.catalog
    }

    /// Creates a Cursor adapter.
    public init() {}

    public func detect(in env: AgentEnvironment) async -> DetectionResult {
        let userDir = CursorPathCatalog.userCursorDirectory(in: env)
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
        CursorDiscovery.discover(in: env, folder: folder)
    }

    public func resolve(_ artifacts: [Artifact], folder: URL, env: AgentEnvironment) -> Resolution {
        CursorResolver.resolve(artifacts, folder: folder, env: env)
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
        CursorLogDecoder()
    }

    public func fixSupport() -> FixSupport {
        FixSupport()
    }
}
