/// An active artifact entry inside a folder's precedence-resolved `Resolution`.
public struct ResolvedArtifact: Sendable, Codable, Hashable {
    /// Identifier of the winning `Artifact`.
    public var artifactID: ArtifactID
    /// Effective `LoadMode` after applying project/user approvals and settings.
    public var effectiveLoadMode: LoadMode
    /// Human-readable explanation of why this artifact is active.
    public var reason: String

    /// Creates a resolved artifact entry.
    public init(artifactID: ArtifactID, effectiveLoadMode: LoadMode, reason: String) {
        self.artifactID = artifactID
        self.effectiveLoadMode = effectiveLoadMode
        self.reason = reason
    }
}
