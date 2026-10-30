import BentoCore
import Foundation

/// Parsed Cursor `.mdc` rule document combining frontmatter directives with a `RulesDoc` payload.
public struct MDCDocument: Sendable, Codable, Hashable {
    /// Optional rule description used for agent-requested activation.
    public var description: String?
    /// File glob patterns scoping when the rule applies.
    public var globs: [String]
    /// Whether the rule is unconditionally injected into every session.
    public var alwaysApply: Bool
    /// Effective `LoadMode` derived from `alwaysApply`, `globs`, and `description`.
    public var effectiveLoadMode: LoadMode
    /// Underlying `RulesDoc` payload ready for `ArtifactPayload.rules`.
    public var rulesDoc: RulesDoc
    /// 1-based line number in the `.mdc` file where the Markdown body starts.
    public var bodyStartLine: Int
    /// Non-fatal diagnostics encountered while parsing the `.mdc` file.
    public var diagnostics: [Diagnostic]

    /// Creates a parsed `.mdc` rule document.
    public init(
        description: String?,
        globs: [String],
        alwaysApply: Bool,
        effectiveLoadMode: LoadMode,
        rulesDoc: RulesDoc,
        bodyStartLine: Int,
        diagnostics: [Diagnostic] = []
    ) {
        self.description = description
        self.globs = globs
        self.alwaysApply = alwaysApply
        self.effectiveLoadMode = effectiveLoadMode
        self.rulesDoc = rulesDoc
        self.bodyStartLine = bodyStartLine
        self.diagnostics = diagnostics
    }
}
