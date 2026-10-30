import BentoCore
import Foundation

/// Parsed result of splitting optional YAML frontmatter from a Markdown document.
public struct FrontmatterDocument: Sendable, Codable, Hashable {
    /// Redacted frontmatter key-value dictionary, or `nil` when no valid frontmatter block was present.
    public var frontmatter: [String: JSONValue]?
    /// Markdown body text following the frontmatter block.
    public var body: String
    /// 1-based line number in the original file where `body` begins.
    public var bodyStartLine: Int
    /// Non-fatal diagnostics produced while parsing frontmatter.
    public var diagnostics: [Diagnostic]

    /// Creates a parsed frontmatter document.
    public init(
        frontmatter: [String: JSONValue]?,
        body: String,
        bodyStartLine: Int,
        diagnostics: [Diagnostic] = []
    ) {
        self.frontmatter = frontmatter
        self.body = body
        self.bodyStartLine = bodyStartLine
        self.diagnostics = diagnostics
    }
}
