import BentoCore

/// Namespace marker for local SQLite persistence inside the app support directory.
public enum BentoStoreModule: Sendable {
    /// Module identifier used for diagnostics and logging categories.
    public static let category = "store"
}
