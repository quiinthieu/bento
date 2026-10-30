/// Epistemic confidence level of a token count measurement or estimate.
public enum Confidence: String, Sendable, Codable, CaseIterable {
    /// Counted by the provider API or a known-exact tokenizer for the target model.
    case exact
    /// Computed by an offline tokenizer or calibrated heuristic.
    case estimated
    /// Derived empirically from local session usage logs.
    case measured
}
