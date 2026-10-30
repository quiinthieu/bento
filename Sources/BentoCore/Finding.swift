/// Actionable hygiene, duplication, conflict, size-limit, or unused-artifact finding.
public struct Finding: Sendable, Codable, Identifiable, Hashable {
    /// Classification of hygiene or usage finding.
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case nearDuplicate
        case exactDuplicate
        case conflict
        case sizeLimit
        case unused
        case brokenImport
        case shadowed
        case invalidConfig
    }

    /// Deterministic finding identifier.
    public var id: String
    /// Finding category.
    public var kind: Kind
    /// Severity level.
    public var severity: Severity
    /// Related artifact identifiers.
    public var artifacts: [ArtifactID]
    /// Highlighted source file locations or line ranges.
    public var spans: [SourceLocation]
    /// Human-readable description of the finding.
    public var message: String
    /// Candidate reversible fixes applicable to this finding.
    public var suggestedFixes: [FixKind]

    /// Creates a hygiene or usage finding.
    public init(
        id: String,
        kind: Kind,
        severity: Severity,
        artifacts: [ArtifactID],
        spans: [SourceLocation] = [],
        message: String,
        suggestedFixes: [FixKind] = []
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.artifacts = artifacts
        self.spans = spans
        self.message = message
        self.suggestedFixes = suggestedFixes
    }
}
