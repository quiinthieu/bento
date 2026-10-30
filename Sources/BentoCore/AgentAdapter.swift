import Foundation

/// Contract implemented by every supported AI coding agent integration.
public protocol AgentAdapter: Sendable {
    /// Static identifier of the agent.
    static var id: AgentID { get }
    /// Human-readable agent name.
    var displayName: String { get }
    /// Supported feature capabilities for this adapter.
    var capabilities: AgentCapabilities { get }
    /// Verified catalog of all configuration and log paths inspected by this adapter.
    var paths: PathCatalog { get }

    /// Checks whether the agent is installed or configured in `env`.
    func detect(in env: AgentEnvironment) async -> DetectionResult

    /// Discovers all artifacts at global scope plus those reachable from `folder`.
    func discover(in env: AgentEnvironment, folder: URL?) async throws -> [Artifact]

    /// Orders and merges discovered artifacts as the agent would when launched in `folder`.
    func resolve(_ artifacts: [Artifact], folder: URL, env: AgentEnvironment) -> Resolution

    /// Static built-in system prompt and tool overhead per model.
    func builtInBudget(model: String?) -> [BudgetItem]

    /// Maps a resolved artifact into context budget contributions.
    func budgetContributions(for resolved: ResolvedArtifact, artifact: Artifact) -> [BudgetContribution]

    /// Discovers local session log files inside `env`.
    func logSources(in env: AgentEnvironment) throws -> [LogSource]

    /// Creates a fresh streaming log line decoder for this agent.
    func makeLogDecoder() -> any LogDecoder

    /// Declares supported reversible fixes for this agent.
    func fixSupport() -> FixSupport
}
