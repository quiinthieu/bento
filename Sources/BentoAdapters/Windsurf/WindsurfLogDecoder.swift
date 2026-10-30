import BentoCore
import Foundation

/// No-op log decoder for Windsurf (`capabilities` exclude `.usageLogs` in v1 per `PLAN.md` §11).
public struct WindsurfLogDecoder: LogDecoder, Sendable {
    /// Creates a Windsurf log decoder.
    public init() {}

    public mutating func decode(line: Data, source: LogSource) -> [UsageEvent] {
        []
    }
}
