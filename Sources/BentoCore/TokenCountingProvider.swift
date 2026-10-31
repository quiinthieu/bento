/// Resolves the appropriate `TokenCounter`, confidence, method, and context window for an `(AgentID, model)` pair.
public protocol TokenCountingProvider: Sendable {
    /// Counts or estimates tokens for `text` under `(agent, model)`, using `contentHash` caching when supplied.
    func estimateTokens(
        text: String,
        contentHash: String?,
        agent: AgentID,
        model: String?
    ) -> TokenCountEstimate

    /// Returns the known context window capacity in tokens for `(agent, model)`, if documented.
    func contextWindow(for agent: AgentID, model: String?) -> Int?
}
