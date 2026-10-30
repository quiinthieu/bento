/// Bitmask of audit and management capabilities supported by an `AgentAdapter`.
public struct AgentCapabilities: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Read-only artifact discovery.
    public static let inventory = AgentCapabilities(rawValue: 1 << 0)
    /// Folder-scoped precedence and shadowing resolution.
    public static let resolution = AgentCapabilities(rawValue: 1 << 1)
    /// Pre-prompt context token budget calculation.
    public static let budget = AgentCapabilities(rawValue: 1 << 2)
    /// Local session usage log ingestion and calibration.
    public static let usageLogs = AgentCapabilities(rawValue: 1 << 3)
    /// Consented MCP server schema probing.
    public static let mcpProbe = AgentCapabilities(rawValue: 1 << 4)
    /// Reversible configuration fixes.
    public static let fixes = AgentCapabilities(rawValue: 1 << 5)
}
