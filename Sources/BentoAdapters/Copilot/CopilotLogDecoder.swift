import BentoCore
import Foundation

/// Streaming log decoder placeholder for GitHub Copilot CLI (full implementation scheduled in T11 `BentoLogIngest`).
public struct CopilotLogDecoder: LogDecoder, Sendable {
    /// Creates a Copilot CLI log decoder.
    public init() {}

    public mutating func decode(line: Data, source: LogSource) -> [UsageEvent] {
        []
    }
}
