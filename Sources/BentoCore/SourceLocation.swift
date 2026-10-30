/// Filesystem and structured-document coordinates where an artifact or finding originates.
public struct SourceLocation: Sendable, Codable, Hashable {
    /// Absolute path as discovered (symlinks not resolved).
    public var path: String
    /// Absolute path with symlinks resolved.
    public var realPath: String
    /// Optional structured key path (for example `["mcpServers", "github"]`).
    public var keyPath: [String]?
    /// Optional 1-based inclusive line span within the source file.
    public var lineRange: ClosedRange<Int>?

    /// Creates a source location record.
    public init(
        path: String,
        realPath: String,
        keyPath: [String]? = nil,
        lineRange: ClosedRange<Int>? = nil
    ) {
        self.path = path
        self.realPath = realPath
        self.keyPath = keyPath
        self.lineRange = lineRange
    }
}
