import CryptoKit
import Foundation

/// Stable deterministic identifier for an `Artifact`, derived via SHA-256 over
/// `(agent, kind, scope, path, keyPath)`.
public struct ArtifactID: RawRepresentable, Sendable, Codable, Hashable, Comparable, CustomStringConvertible {
    /// Lowercase 64-character hexadecimal SHA-256 digest (or explicit test identifier).
    public var rawValue: String

    /// Creates an `ArtifactID` from an existing raw string value.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Computes a collision-resistant SHA-256 `ArtifactID` using length-prefixed canonical components.
    public init(
        agent: AgentID,
        kind: ArtifactKind,
        scope: Scope,
        path: String,
        keyPath: [String]? = nil
    ) {
        var canonical = ""
        Self.appendField(agent.rawValue, to: &canonical)
        Self.appendField(kind.rawValue, to: &canonical)
        Self.appendField(scope.identifier, to: &canonical)
        Self.appendField(path, to: &canonical)

        if let keyPath {
            canonical.append("K\(keyPath.count):")
            for segment in keyPath {
                Self.appendField(segment, to: &canonical)
            }
        } else {
            canonical.append("N;")
        }

        let digest = SHA256.hash(data: Data(canonical.utf8))
        self.rawValue = digest.map { String(format: "%02x", $0) }.joined()
    }

    public var description: String {
        rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: ArtifactID, rhs: ArtifactID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    private static func appendField(_ value: String, to buffer: inout String) {
        buffer.append("\(value.utf8.count)#")
        buffer.append(value)
        buffer.append("|")
    }
}
