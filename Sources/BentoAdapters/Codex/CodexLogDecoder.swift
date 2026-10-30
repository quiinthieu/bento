import BentoCore
import Foundation

/// Streaming JSONL rollout log decoder for OpenAI Codex CLI.
/// Full token-usage (`token_count`), `session_meta`, and function-call decoding is implemented in T11 (`BentoLogIngest`).
public struct CodexLogDecoder: LogDecoder, Sendable {
    /// Creates a Codex CLI log decoder.
    public init() {}

    public mutating func decode(line: Data, source: LogSource) -> [UsageEvent] {
        []
    }
}
