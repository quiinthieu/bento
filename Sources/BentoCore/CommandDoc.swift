/// Parsed payload for a slash command definition (Markdown or TOML).
public struct CommandDoc: Sendable, Codable, Hashable {
    /// Slash command name without leading slash.
    public var name: String
    /// Short command summary.
    public var description: String?
    /// Optional argument hint string.
    public var argumentHint: String?
    /// Prompt template body expanded upon invocation.
    public var body: String

    /// Creates a command document payload.
    public init(
        name: String,
        description: String? = nil,
        argumentHint: String? = nil,
        body: String
    ) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.body = body
    }
}
