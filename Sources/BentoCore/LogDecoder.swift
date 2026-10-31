import Foundation

/// Stateful per-file line decoder transforming raw JSONL lines into privacy-safe `UsageEvent` records.
public protocol LogDecoder: Sendable {
    /// Decodes a single UTF-8 JSON line from `source`, tolerating unknown fields and event types.
    mutating func decode(line: Data, source: LogSource) -> [UsageEvent]

    /// Decodes a complete monolithic JSON or JSONL document (used for legacy `.json` chat files).
    mutating func decodeDocument(data: Data, source: LogSource) -> [UsageEvent]

    /// Number of malformed lines or schema errors encountered and skipped while decoding this file.
    var errorCount: Int { get }

    /// Latest model identifier observed per `sessionID` during decoding.
    var observedModelsBySession: [String: String] { get }

    /// Character count (length only — never text) of the first user turn per `sessionID`, used to subtract
    /// user-prompt length when fitting pre-prompt calibration factors (`PLAN.md` §6.3).
    var firstUserMessageCharCountsBySession: [String: Int] { get }

    /// Serializes per-file incremental decoder state so subsequent `offset_consumed` reads retain session context.
    func exportResumeState() -> Data?

    /// Restores previously exported incremental decoder state before resuming from `offset_consumed`.
    mutating func restoreResumeState(_ data: Data)
}

extension LogDecoder {
    public mutating func decodeDocument(data: Data, source: LogSource) -> [UsageEvent] {
        var events: [UsageEvent] = []
        var lineStart = 0
        let count = data.count
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for idx in 0..<count where base[idx] == 0x0A {
                var end = idx
                if end > lineStart && base[end - 1] == 0x0D {
                    end -= 1
                }
                if end > lineStart {
                    let slice = Data(bytes: base.advanced(by: lineStart), count: end - lineStart)
                    events.append(contentsOf: decode(line: slice, source: source))
                }
                lineStart = idx + 1
            }
            if lineStart < count {
                var end = count
                if end > lineStart && base[end - 1] == 0x0D {
                    end -= 1
                }
                if end > lineStart {
                    let slice = Data(bytes: base.advanced(by: lineStart), count: end - lineStart)
                    events.append(contentsOf: decode(line: slice, source: source))
                }
            }
        }
        return events
    }

    public var errorCount: Int { 0 }

    public var observedModelsBySession: [String: String] { [:] }

    public var firstUserMessageCharCountsBySession: [String: Int] { [:] }

    public func exportResumeState() -> Data? { nil }

    public mutating func restoreResumeState(_ data: Data) {}
}
