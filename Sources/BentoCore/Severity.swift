/// Severity level for diagnostics and hygiene findings.
public enum Severity: String, Sendable, Codable, CaseIterable, Comparable {
    case info
    case warning
    case error

    private var rank: Int {
        switch self {
        case .info:
            return 0
        case .warning:
            return 1
        case .error:
            return 2
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.rank < rhs.rank
    }
}
