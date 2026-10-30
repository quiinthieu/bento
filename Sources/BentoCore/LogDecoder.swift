import Foundation

/// Stateful per-file line decoder transforming raw JSONL lines into privacy-safe `UsageEvent` records.
public protocol LogDecoder: Sendable {
    /// Decodes a single UTF-8 JSON line from `source`, tolerating unknown fields and event types.
    mutating func decode(line: Data, source: LogSource) -> [UsageEvent]
}
