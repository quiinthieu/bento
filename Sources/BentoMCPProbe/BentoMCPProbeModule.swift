import BentoCore

/// Namespace marker for explicit-consent MCP server probing.
public enum BentoMCPProbeModule: Sendable {
    /// Module identifier used for diagnostics and logging categories.
    public static let category = "mcp-probe"
}
