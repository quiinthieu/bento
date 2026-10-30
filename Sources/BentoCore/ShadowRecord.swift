/// Records an artifact that was overridden or shadowed by a higher-precedence artifact during resolution.
public struct ShadowRecord: Sendable, Codable, Hashable {
    /// Identifier of the lower-precedence artifact that was shadowed.
    public var shadowedArtifactID: ArtifactID
    /// Identifier of the higher-precedence artifact that took precedence.
    public var winningArtifactID: ArtifactID
    /// Human-readable reason explaining the override rule.
    public var reason: String

    /// Creates a shadow record.
    public init(shadowedArtifactID: ArtifactID, winningArtifactID: ArtifactID, reason: String) {
        self.shadowedArtifactID = shadowedArtifactID
        self.winningArtifactID = winningArtifactID
        self.reason = reason
    }
}
