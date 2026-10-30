import BentoCore
import Foundation

/// Result of recursively resolving `@import` directives from a root Markdown document.
public struct ImportResolution: Sendable, Codable, Hashable {
    /// Root document URL from which resolution began.
    public var rootURL: URL
    /// Direct `@import` target strings extracted from the root document.
    public var directImports: [String]
    /// Ordered URLs of transitively resolved imported files (depth-first, deduplicated).
    public var resolvedFiles: [URL]
    /// Flattened Markdown content with valid imported files expanded inline.
    public var expandedContent: String
    /// Diagnostics emitted for cycles, depth limits, missing files, symlink loops, or invalid UTF-8.
    public var diagnostics: [Diagnostic]

    /// Creates an import resolution result.
    public init(
        rootURL: URL,
        directImports: [String],
        resolvedFiles: [URL],
        expandedContent: String,
        diagnostics: [Diagnostic]
    ) {
        self.rootURL = rootURL
        self.directImports = directImports
        self.resolvedFiles = resolvedFiles
        self.expandedContent = expandedContent
        self.diagnostics = diagnostics
    }
}
