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
    /// Optional injected home directory path for expanding `<HOME>/` or `~/` prefixes hermetically.
    public var homePath: String?

    /// Creates a log source descriptor.
    public init(
        agent: AgentID,
        url: URL,
        isCompressed: Bool = false,
        inferredCwd: String? = nil,
        homePath: String? = nil
    ) {
        self.agent = agent
        self.url = url
        self.isCompressed = isCompressed
        self.inferredCwd = inferredCwd
        self.homePath = homePath
    }

    /// Normalizes a raw `cwd` string from a log entry against `homePath` without touching real `$HOME`.
    public func normalizeLoggedCwd(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return inferredCwd
        }
        if let homePath, !homePath.isEmpty {
            let base = URL(fileURLWithPath: homePath, isDirectory: true).standardizedFileURL
            if trimmed == "~" || trimmed == "<HOME>" {
                return base.path
            }
            if trimmed.hasPrefix("~/") {
                return base.appendingPathComponent(String(trimmed.dropFirst(2))).standardizedFileURL.path
            }
            if trimmed.hasPrefix("<HOME>/") {
                return base.appendingPathComponent(String(trimmed.dropFirst("<HOME>/".count)))
                    .standardizedFileURL.path
            }
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }
        return trimmed
    }
}
