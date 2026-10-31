/// Token count paired with confidence, provenance method, and optional uncertainty interval (`PLAN.md` §4.1, §6.3).
public struct TokenCountEstimate: Sendable, Codable, Hashable {
    /// Point token count or estimate.
    public var tokens: Int
    /// Optional uncertainty interval for estimated counts.
    public var range: ClosedRange<Int>?
    /// Confidence classification (`exact`, `estimated`, or `measured`).
    public var confidence: Confidence
    /// Human-readable provenance method (for example `"o200k_base"` or `"heuristic chars/3.8"`).
    public var method: String
    /// Identifier of the underlying `TokenCounter`.
    public var counterID: String

    /// Creates a token count estimate descriptor.
    public init(
        tokens: Int,
        range: ClosedRange<Int>? = nil,
        confidence: Confidence,
        method: String,
        counterID: String
    ) {
        self.tokens = tokens
        self.range = range
        self.confidence = confidence
        self.method = method
        self.counterID = counterID
    }
}
