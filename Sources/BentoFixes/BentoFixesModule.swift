import BentoCore
import BentoParsing
import BentoStore

/// Namespace marker for reversible configuration fix planning, diffing, backup, apply, and undo.
public enum BentoFixesModule: Sendable {
    /// Module identifier used for diagnostics and logging categories.
    public static let category = "fixes"
}
