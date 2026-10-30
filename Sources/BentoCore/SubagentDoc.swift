/// Parsed payload for a custom subagent definition (e.g. `.claude/agents/*.md`, `.github/agents/*.agent.md`).
public struct SubagentDoc: Sendable, Codable, Hashable {
    /// Subagent name.
    public var name: String
    /// Description advertised to the parent agent's delegation tool.
    public var description: String?
    /// Optional model override configured for the subagent.
    public var model: String?
    /// Optional list of allowed tools declared in frontmatter.
    public var tools: [String]?
    /// Redacted frontmatter dictionary.
    public var frontmatter: [String: JSONValue]
    /// System prompt body loaded when the subagent runs.
    public var body: String

    /// Creates a subagent document payload.
    public init(
        name: String,
        description: String? = nil,
        model: String? = nil,
        tools: [String]? = nil,
        frontmatter: [String: JSONValue] = [:],
        body: String
    ) {
        self.name = name
        self.description = description
        self.model = model
        self.tools = tools
        self.frontmatter = frontmatter
        self.body = body
    }
}
