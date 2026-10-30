import BentoAdapters
import BentoCore

/// Namespace marker for filesystem scanning and incremental rescan orchestration.
public enum BentoScannerModule: Sendable {
    /// Module identifier used for diagnostics and logging categories.
    public static let category = "scanner"
}
