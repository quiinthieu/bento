/// Parsed manifest describing an installed agent plugin or extension bundle.
public struct PluginManifest: Sendable, Codable, Hashable {
    /// Plugin or extension name.
    public var name: String
    /// Optional semantic version string.
    public var version: String?
    /// Optional human-readable summary.
    public var description: String?
    /// Skill names contributed by the plugin.
    public var skills: [String]
    /// Subagent names contributed by the plugin.
    public var agents: [String]
    /// Command names contributed by the plugin.
    public var commands: [String]
    /// MCP server names contributed by the plugin.
    public var mcpServers: [String]

    /// Creates a plugin manifest payload.
    public init(
        name: String,
        version: String? = nil,
        description: String? = nil,
        skills: [String] = [],
        agents: [String] = [],
        commands: [String] = [],
        mcpServers: [String] = []
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.skills = skills
        self.agents = agents
        self.commands = commands
        self.mcpServers = mcpServers
    }
}
