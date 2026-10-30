/// Parsed payload for an agent skill (`SKILL.md` plus supporting directory files).
public struct SkillDoc: Sendable, Codable, Hashable {
    /// Skill identifier or frontmatter `name`.
    public var name: String
    /// Skill trigger description loaded into always-on frontmatter context.
    public var description: String?
    /// Redacted frontmatter dictionary.
    public var frontmatter: [String: JSONValue]
    /// Markdown body loaded when the skill is invoked.
    public var body: String
    /// Relative paths of supporting scripts, examples, or references inside the skill folder.
    public var supportingFiles: [String]

    /// Creates a skill document payload.
    public init(
        name: String,
        description: String? = nil,
        frontmatter: [String: JSONValue] = [:],
        body: String,
        supportingFiles: [String] = []
    ) {
        self.name = name
        self.description = description
        self.frontmatter = frontmatter
        self.body = body
        self.supportingFiles = supportingFiles
    }
}
