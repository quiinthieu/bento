import Foundation

/// Errors thrown by parsers in `BentoParsing`.
public enum BentoParsingError: Error, Sendable, Equatable {
    /// Input bytes could not be decoded as valid UTF-8.
    case invalidUTF8
    /// JSON or JSONC syntax error at a 1-based line and column.
    case malformedJSON(message: String, line: Int, column: Int)
    /// Expected a top-level JSON object (`{ ... }`), but parsed another value type.
    case expectedJSONObject
    /// Recursive structure exceeded the configured maximum nesting depth.
    case nestingLimitExceeded(maxDepth: Int, line: Int)
    /// TOML syntax or type error.
    case malformedTOML(message: String)
    /// YAML frontmatter syntax error.
    case malformedFrontmatter(message: String, line: Int?)
    /// Expected YAML frontmatter root to be a key-value mapping.
    case expectedFrontmatterMapping
}
