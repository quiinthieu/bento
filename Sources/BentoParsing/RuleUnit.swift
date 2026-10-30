import Foundation

/// Individual directive unit extracted from a Markdown rules document (`PLAN.md` §6.5).
public struct RuleUnit: Sendable, Codable, Hashable {
    /// Syntactic construct from which the rule unit originated.
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case bullet
        case numbered
        case paragraph
    }

    /// Construct kind (`bullet`, `numbered`, or `paragraph` sentence).
    public var kind: Kind
    /// Active ATX heading breadcrumb above this unit (outermost to innermost).
    public var headingPath: [String]
    /// Original unnormalized Markdown text of this unit.
    public var rawText: String
    /// Lowercased, whitespace-collapsed, Markdown-stripped canonical text for deduplication and hygiene.
    public var normalizedText: String
    /// 1-based inclusive line range of this unit in the source file.
    public var lineRange: ClosedRange<Int>

    /// Creates a rule unit.
    public init(
        kind: Kind,
        headingPath: [String],
        rawText: String,
        normalizedText: String,
        lineRange: ClosedRange<Int>
    ) {
        self.kind = kind
        self.headingPath = headingPath
        self.rawText = rawText
        self.normalizedText = normalizedText
        self.lineRange = lineRange
    }
}
