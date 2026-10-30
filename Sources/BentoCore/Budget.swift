/// Complete context token budget breakdown for one agent in a specific folder.
public struct Budget: Sendable, Codable, Hashable {
    /// Target coding agent.
    public var agent: AgentID
    /// Target repository or working directory path.
    public var folder: String
    /// Optional model identifier used for tokenization and context window lookup.
    public var model: String?
    /// Individual built-in, always-on, conditional, and deferred budget items.
    public var items: [BudgetItem]
    /// Optional median first-turn input token count observed in local session logs.
    public var measuredFirstTurnInput: Int?
    /// Optional total context window capacity in tokens for `model`.
    public var contextWindow: Int?

    /// Sum of tokens across items where `countsTowardPrePrompt` is `true`.
    public var prePromptTokens: Int {
        items.reduce(0) { sum, item in
            item.countsTowardPrePrompt ? sum + item.tokens : sum
        }
    }

    /// Creates a context budget summary.
    public init(
        agent: AgentID,
        folder: String,
        model: String? = nil,
        items: [BudgetItem],
        measuredFirstTurnInput: Int? = nil,
        contextWindow: Int? = nil
    ) {
        self.agent = agent
        self.folder = folder
        self.model = model
        self.items = items
        self.measuredFirstTurnInput = measuredFirstTurnInput
        self.contextWindow = contextWindow
    }
}
