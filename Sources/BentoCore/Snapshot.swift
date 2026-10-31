import Foundation

/// Immutable point-in-time inventory and precedence resolution state across all agents and discovered repositories.
public struct Snapshot: Sendable, Identifiable, Hashable {
    /// Unique snapshot identifier.
    public var id: String
    /// Capture timestamp.
    public var createdAt: Date
    /// Standardized target home directory path inspected during this scan.
    public var homePath: String
    /// Lowercase SHA-256 hex digest of `homePath`.
    public var homeHash: String
    /// Scanner marketing version (`Product.version`).
    public var scannerVersion: String
    /// Per-agent installation/configuration detection results.
    public var detections: [AgentID: DetectionResult]
    /// Deduplicated discovered repositories sorted by `path`.
    public var repos: [DiscoveredRepo]
    /// Exact discovered artifacts keyed by `(agent, repoPath)` scope (`nil` for global scope).
    public var scopedArtifacts: [ScanScope: [Artifact]]
    /// Precedence resolutions across `(agent, repo)` pairs sorted by `(folder, agent)`.
    public var resolutions: [Resolution]

    /// Creates a normalized immutable workspace snapshot.
    public init(
        id: String = UUID().uuidString.lowercased(),
        createdAt: Date,
        homePath: String,
        homeHash: String? = nil,
        scannerVersion: String = Product.version,
        detections: [AgentID: DetectionResult] = [:],
        repos: [DiscoveredRepo] = [],
        scopedArtifacts: [ScanScope: [Artifact]] = [:],
        resolutions: [Resolution] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.homePath = homePath
        self.homeHash = homeHash ?? ContentHasher.sha256Hex(Data(homePath.utf8))
        self.scannerVersion = scannerVersion
        self.detections = detections
        self.repos = repos.sorted { $0.path < $1.path }
        self.scopedArtifacts = scopedArtifacts
        self.resolutions = resolutions.sorted { lhs, rhs in
            if lhs.folder != rhs.folder {
                return lhs.folder < rhs.folder
            }
            return lhs.agent < rhs.agent
        }
    }

    /// Deterministically ordered, deduplicated union of all discovered artifacts across global and repository scopes.
    public var artifacts: [Artifact] {
        var seen: Set<ArtifactID> = []
        var result: [Artifact] = []
        for scope in scopedArtifacts.keys.sorted() {
            guard let list = scopedArtifacts[scope] else { continue }
            for artifact in list where seen.insert(artifact.id).inserted {
                result.append(artifact)
            }
        }
        return result
    }

    /// Returns artifacts matching optional `agent` and `repoPath` filters.
    ///
    /// When `repoPath` is provided, returns the exact discovery list for `(agent, repoPath)` (resolving
    /// either `repo.path` or `repo.realPath` when the repository is in `repos`). When `repoPath` is `nil`,
    /// returns the deduplicated union across global and repository scopes filtered by `agent`.
    public func artifacts(agent: AgentID? = nil, repoPath: String? = nil) -> [Artifact] {
        guard let rawRepoPath = repoPath else {
            guard let agent else { return artifacts }
            return artifacts.filter { $0.agent == agent }
        }

        let canonicalRepoPath = resolveCanonicalRepoPath(rawRepoPath)
        let targetAgents = agent.map { [$0] } ?? AgentID.allCases.sorted()
        var seen: Set<ArtifactID> = []
        var result: [Artifact] = []
        for targetAgent in targetAgents {
            let scope = ScanScope(agent: targetAgent, repoPath: canonicalRepoPath)
            guard let list = scopedArtifacts[scope] else { continue }
            for artifact in list where seen.insert(artifact.id).inserted {
                result.append(artifact)
            }
        }
        return result
    }

    /// Looks up the stored `Resolution` for `agent` in `repoPath` (matching either `path` or `realPath` of known repos).
    public func resolution(for agent: AgentID, repoPath: String) -> Resolution? {
        let canonical = resolveCanonicalRepoPath(repoPath)
        return resolutions.first { $0.agent == agent && $0.folder == canonical }
    }

    /// Resolves `candidatePath` against `repos` (`path` or `realPath`), falling back to standardized URL path.
    public func resolveCanonicalRepoPath(_ candidatePath: String) -> String {
        let standardized = URL(fileURLWithPath: candidatePath).standardizedFileURL.path
        if let matched = repos.first(where: { $0.path == standardized || $0.realPath == standardized }) {
            return matched.path
        }
        return standardized
    }
}

extension Snapshot: Codable {
    private struct ScopedEntry: Codable, Hashable {
        var scope: ScanScope
        var artifacts: [Artifact]
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case homePath
        case homeHash
        case scannerVersion
        case detections
        case repos
        case scopedArtifacts
        case resolutions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let homePath = try container.decode(String.self, forKey: .homePath)
        let homeHash = try container.decode(String.self, forKey: .homeHash)
        let scannerVersion = try container.decode(String.self, forKey: .scannerVersion)
        let detections = try container.decode([AgentID: DetectionResult].self, forKey: .detections)
        let repos = try container.decode([DiscoveredRepo].self, forKey: .repos)
        let entries = try container.decode([ScopedEntry].self, forKey: .scopedArtifacts)
        let resolutions = try container.decode([Resolution].self, forKey: .resolutions)

        var map: [ScanScope: [Artifact]] = [:]
        for entry in entries {
            map[entry.scope] = entry.artifacts
        }

        self.init(
            id: id,
            createdAt: createdAt,
            homePath: homePath,
            homeHash: homeHash,
            scannerVersion: scannerVersion,
            detections: detections,
            repos: repos,
            scopedArtifacts: map,
            resolutions: resolutions
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(homePath, forKey: .homePath)
        try container.encode(homeHash, forKey: .homeHash)
        try container.encode(scannerVersion, forKey: .scannerVersion)
        try container.encode(detections, forKey: .detections)
        try container.encode(repos, forKey: .repos)
        let entries = scopedArtifacts.keys.sorted().map { key in
            ScopedEntry(scope: key, artifacts: scopedArtifacts[key] ?? [])
        }
        try container.encode(entries, forKey: .scopedArtifacts)
        try container.encode(resolutions, forKey: .resolutions)
    }
}
