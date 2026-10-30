import BentoCore
import BentoParsing

/// Namespace marker for per-agent `AgentAdapter` implementations.
public enum BentoAdaptersModule: Sendable {
    /// Module identifier used for diagnostics and logging categories.
    public static let category = "adapters"
}
