/// Precedence tier of a discovered configuration artifact.
/// Lower raw values denote higher priority unless overridden by an adapter's resolution rules.
public enum Scope: Int, Sendable, Codable, CaseIterable, Comparable {
    case managed = 0
    case projectLocal = 1
    case project = 2
    case directory = 3
    case user = 4
    case builtIn = 5

    /// Stable textual identifier used in `ArtifactID` hashing and human-readable reports.
    public var identifier: String {
        switch self {
        case .managed:
            return "managed"
        case .projectLocal:
            return "projectLocal"
        case .project:
            return "project"
        case .directory:
            return "directory"
        case .user:
            return "user"
        case .builtIn:
            return "builtIn"
        }
    }

    public static func < (lhs: Scope, rhs: Scope) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
