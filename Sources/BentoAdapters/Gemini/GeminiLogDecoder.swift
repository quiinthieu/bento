import BentoCore
import Foundation

/// Streaming chat transcript decoder for Google Gemini CLI.
/// Full token-usage and tool-call decoding is implemented in T11 (`BentoLogIngest`).
public struct GeminiLogDecoder: LogDecoder, Sendable {
    /// Creates a Gemini CLI log decoder.
    public init() {}

    public mutating func decode(line: Data, source: LogSource) -> [UsageEvent] {
        []
    }
}
