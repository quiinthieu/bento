import BentoCore
import Foundation

/// Typed errors emitted by `BentoLogIngest` when opening or seeking a local log file fails.
public enum BentoLogIngestError: Error, Sendable, LocalizedError {
    case unreadableLogFile(path: String, underlyingDescription: String)
    case seekFailed(path: String, offset: UInt64, errnoCode: Int32)
    case readFailed(path: String, errnoCode: Int32)
    case zstdStreamAllocationFailed

    public var errorDescription: String? {
        switch self {
        case .unreadableLogFile(let path, let desc):
            return "Unable to open log file for reading at '\(path)': \(desc)"
        case .seekFailed(let path, let offset, let code):
            return "Failed to seek log file '\(path)' to offset \(offset) (errno \(code))."
        case .readFailed(let path, let code):
            return "Failed to read log file '\(path)' (errno \(code))."
        case .zstdStreamAllocationFailed:
            return "Failed to allocate ZSTD_DStream decompression context."
        }
    }
}

/// Summary returned after streaming complete `\n`-terminated lines from a plain or `.zst` log file.
public struct LineReadOutcome: Sendable, Equatable {
    /// Committed byte offset immediately after the last `\n` (for plain JSONL files).
    public var consumedOffset: UInt64
    /// Total physical bytes read from disk during this pass.
    public var bytesRead: UInt64
    /// Non-fatal diagnostics (such as `ingest.lineOversized` or `ingest.zstdTruncated`).
    public var diagnostics: [Diagnostic]
    /// Human-readable decompression or stream error recorded into `log_file.last_error`, if any.
    public var errorMessage: String?

    public init(
        consumedOffset: UInt64,
        bytesRead: UInt64,
        diagnostics: [Diagnostic] = [],
        errorMessage: String? = nil
    ) {
        self.consumedOffset = consumedOffset
        self.bytesRead = bytesRead
        self.diagnostics = diagnostics
        self.errorMessage = errorMessage
    }
}
