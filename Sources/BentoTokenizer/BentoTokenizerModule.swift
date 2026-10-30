import BentoCore

/// Namespace marker for offline BPE/heuristic tokenizers, calibration, and opt-in API counters.
public enum BentoTokenizerModule: Sendable {
    /// Module identifier used for diagnostics and logging categories.
    public static let category = "tokenizer"
}
