/// A single line item contributing to (or deferred from) an agent's pre-prompt token budget.
public struct BudgetItem: Sendable, Codable, Hashable {
    /// Associated artifact identifier, or `nil` for built-in system/tool overhead.
    public var artifactID: ArtifactID?
    /// Budget visualization category.
    public var category: BudgetCategory
    /// Display label for tables and chart tooltips.
    public var label: String
    /// Point token count or estimate.
    public var tokens: Int
    /// Optional uncertainty interval for estimated items.
    public var range: ClosedRange<Int>?
    /// Confidence classification (`exact`, `estimated`, or `measured`).
    public var confidence: Confidence
    /// Provenance method description (e.g. `"o200k_base"`, `"heuristic chars/3.6"`).
    public var method: String
    /// `true` when loaded before the first user prompt; `false` for deferred or on-invoke items.
    public var countsTowardPrePrompt: Bool

    /// Creates a budget item.
    public init(
        artifactID: ArtifactID? = nil,
        category: BudgetCategory,
        label: String,
        tokens: Int,
        range: ClosedRange<Int>? = nil,
        confidence: Confidence,
        method: String,
        countsTowardPrePrompt: Bool
    ) {
        self.artifactID = artifactID
        self.category = category
        self.label = label
        self.tokens = tokens
        self.range = range
        self.confidence = confidence
        self.method = method
        self.countsTowardPrePrompt = countsTowardPrePrompt
    }
}
