/// Non-fatal parse, discovery, or resolution diagnostic attached to an artifact or resolution.
public struct Diagnostic: Sendable, Codable, Hashable {
    /// Machine-readable diagnostic code.
    public var code: String
    /// Diagnostic severity.
    public var severity: Severity
    /// Human-readable diagnostic explanation.
    public var message: String
    /// Optional location where the issue occurred.
    public var location: SourceLocation?

    /// Creates a diagnostic record.
    public init(
        code: String,
        severity: Severity,
        message: String,
        location: SourceLocation? = nil
    ) {
        self.code = code
        self.severity = severity
        self.message = message
        self.location = location
    }
}
