/// Result of checking whether an AI coding agent is configured or present in an `AgentEnvironment`.
public struct DetectionResult: Sendable, Codable, Hashable {
    /// `true` if configuration directories, files, or binaries for the agent were detected.
    public var isDetected: Bool
    /// Optional detected agent version string, when determinable read-only.
    public var version: String?
    /// Matched root paths that triggered detection.
    public var detectedPaths: [String]

    /// Creates a detection result.
    public init(isDetected: Bool, version: String? = nil, detectedPaths: [String] = []) {
        self.isDetected = isDetected
        self.version = version
        self.detectedPaths = detectedPaths
    }
}
