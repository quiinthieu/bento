/// Parsed payload for a rules or memory document (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.mdc`, etc.).
public struct RulesDoc: Sendable, Codable, Hashable {
    /// Body text of the rules document.
    public var content: String
    /// Referenced `@import` paths discovered in the document.
    public var imports: [String]
    /// Optional redacted YAML frontmatter metadata (for `.mdc`, `.instructions.md`, Windsurf rules).
    public var frontmatter: [String: JSONValue]?
    /// Raw UTF-8 byte count of the file.
    public var byteCount: Int
    /// Unicode character count of the file.
    public var characterCount: Int
    /// Indicates whether an agent byte/char cap truncated the effective content.
    public var wasTruncated: Bool

    /// Creates a rules document payload.
    public init(
        content: String,
        imports: [String] = [],
        frontmatter: [String: JSONValue]? = nil,
        byteCount: Int,
        characterCount: Int,
        wasTruncated: Bool = false
    ) {
        self.content = content
        self.imports = imports
        self.frontmatter = frontmatter
        self.byteCount = byteCount
        self.characterCount = characterCount
        self.wasTruncated = wasTruncated
    }
}
