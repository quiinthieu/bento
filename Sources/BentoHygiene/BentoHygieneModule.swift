import BentoCore
import BentoParsing
import BentoTokenizer

/// Namespace marker for cross-agent rules hygiene, duplicate detection, and conflict checks.
public enum BentoHygieneModule: Sendable {
    /// Module identifier used for diagnostics and logging categories.
    public static let category = "hygiene"
}
