import Foundation

/// Syntactic `@import` reference discovered in a Markdown rules file.
public struct ImportDirective: Sendable, Codable, Hashable {
    /// Raw token as written in the Markdown source (including leading `@`).
    public var rawToken: String
    /// Unescaped file path referenced by the directive (without leading `@`).
    public var path: String
    /// 1-based line number in the source file where the directive occurred.
    public var line: Int

    /// Creates an import directive record.
    public init(rawToken: String, path: String, line: Int) {
        self.rawToken = rawToken
        self.path = path
        self.line = line
    }
}
