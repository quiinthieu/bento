/// Raw text or pre-estimated token contribution emitted by an adapter before tokenization.
public struct BudgetContribution: Sendable, Codable, Hashable {
    /// Artifact producing this contribution.
    public var artifactID: ArtifactID
    /// Target budget category bucket.
    public var category: BudgetCategory
    /// Human-readable item label.
    public var label: String
    /// Raw text to tokenize, when token count is derived from text content.
    public var text: String?
    /// Fixed fallback token estimate when raw text is unavailable (e.g. unprobed MCP server).
    public var fixedTokensEstimate: Int?
    /// Whether this contribution loads before the user's first prompt.
    public var countsTowardPrePrompt: Bool

    /// Creates a budget contribution descriptor.
    public init(
        artifactID: ArtifactID,
        category: BudgetCategory,
        label: String,
        text: String? = nil,
        fixedTokensEstimate: Int? = nil,
        countsTowardPrePrompt: Bool
    ) {
        self.artifactID = artifactID
        self.category = category
        self.label = label
        self.text = text
        self.fixedTokensEstimate = fixedTokensEstimate
        self.countsTowardPrePrompt = countsTowardPrePrompt
    }
}
