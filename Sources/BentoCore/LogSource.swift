import Foundation

/// Descriptor for a discovered local session log file ready for streaming ingestion.
public struct LogSource: Sendable, Codable, Hashable {
    /// Owning coding agent.
    public var agent: AgentID
    /// File URL of the `.jsonl`, `.json`, or `.jsonl.zst` log file.
    public var url: URL
    /// `true` when the log file uses Zstandard (`.zst`) compression.
    public var isCompressed: Bool
    /// Optional inferred working directory from the log path layout.
    public var inferredCwd: String?

    /// Creates a log source descriptor.
    public init(
        agent: AgentID,
        url: URL,
        isCompressed: Bool = false,
        inferredCwd: String? = nil
    ) {
        self.agent = agent
        self.url = url
        self.isCompressed = isCompressed
        self.inferredCwd = inferredCwd
    }
}
