import BentoCore
import Foundation

/// No-op log decoder for Cursor (`capabilities` exclude `.usageLogs` in v1 per `PLAN.md` §11).
public struct CursorLogDecoder: LogDecoder, Sendable {
    /// Creates a Cursor log decoder.
    public init() {}

    public mutating func decode(line: Data, source: LogSource) -> [UsageEvent] {
        []
    }
}
