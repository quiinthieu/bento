import BentoCore
import BentoParsing

/// Namespace marker for streaming JSONL/zstd session log ingestion.
public enum BentoLogIngestModule: Sendable {
    /// Module identifier used for diagnostics and logging categories.
    public static let category = "log-ingest"
}
