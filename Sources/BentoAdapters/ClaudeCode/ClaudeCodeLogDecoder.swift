import BentoCore
import Foundation

/// Placeholder streaming log line decoder for Claude Code (full JSONL chunk deduplication lands in T11).
public struct ClaudeCodeLogDecoder: LogDecoder, Sendable {
    /// Creates a fresh Claude Code log decoder.
    public init() {}

    public mutating func decode(line: Data, source: LogSource) -> [UsageEvent] {
        []
    }
}
