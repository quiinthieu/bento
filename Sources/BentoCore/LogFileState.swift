import Foundation

/// Persisted cursor and file-identity metadata for a local session log (`PLAN.md` §4.2 `log_file` table).
public struct LogFileState: Sendable, Codable, Hashable {
    /// Standardized absolute file path (`PRIMARY KEY`).
    public var path: String
    /// Owning coding agent.
    public var agent: AgentID
    /// Last observed file size in bytes.
    public var size: UInt64
    /// Last observed modification timestamp.
    public var mtime: Date
    /// Last observed POSIX inode number for rotation detection.
    public var inode: UInt64
    /// Byte offset committed up to the last complete newline (`\n`).
    public var offsetConsumed: UInt64
    /// `true` when the log file is Zstandard-compressed (`.zst`).
    public var isCompressed: Bool
    /// Most recent decompression or decoder diagnostic summary, if any.
    public var lastError: String?
    /// Serialized decoder resume state corresponding to `offsetConsumed`.
    public var decoderState: Data?

    /// Creates a log-file cursor state record.
    public init(
        path: String,
        agent: AgentID,
        size: UInt64,
        mtime: Date,
        inode: UInt64,
        offsetConsumed: UInt64,
        isCompressed: Bool,
        lastError: String? = nil,
        decoderState: Data? = nil
    ) {
        self.path = path
        self.agent = agent
        self.size = size
        self.mtime = mtime
        self.inode = inode
        self.offsetConsumed = offsetConsumed
        self.isCompressed = isCompressed
        self.lastError = lastError
        self.decoderState = decoderState
    }
}
