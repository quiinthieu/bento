import Foundation

/// Options controlling `RepoDiscovery` sources, user pins/hides, and shallow `.git` scanning (PLAN §5.3).
public struct RepoDiscoveryOptions: Sendable, Hashable {
    /// Folders explicitly added by the user.
    public var manualPaths: [URL]
    /// Paths (raw or real) explicitly pinned by the user.
    public var pinnedPaths: Set<String>
    /// Paths (raw or real) hidden by the user (excluded from discovery results).
    public var hiddenPaths: Set<String>
    /// Additional candidate folders tested against Gemini SHA-256 project hashes.
    public var knownCandidatePaths: [URL]
    /// Whether to perform the optional shallow scan (depth <= 3, `.git` present) of `shallowScanRelativeRoots`.
    public var includeShallowScan: Bool
    /// Home-relative root directory names scanned when `includeShallowScan` is `true`.
    public var shallowScanRelativeRoots: [String]
    /// Maximum directory recursion depth under each shallow-scan root (`PLAN.md` §5.3 specifies `<= 3`).
    public var shallowScanMaxDepth: Int

    /// Default shallow-scan root folder names under `env.home` (`PLAN.md` §5.3).
    public static let defaultShallowScanRelativeRoots: [String] = [
        "Developer",
        "code",
        "src",
        "Projects"
    ]

    /// Creates repository discovery options.
    public init(
        manualPaths: [URL] = [],
        pinnedPaths: Set<String> = [],
        hiddenPaths: Set<String> = [],
        knownCandidatePaths: [URL] = [],
        includeShallowScan: Bool = true,
        shallowScanRelativeRoots: [String] = Self.defaultShallowScanRelativeRoots,
        shallowScanMaxDepth: Int = 3
    ) {
        self.manualPaths = manualPaths
        self.pinnedPaths = pinnedPaths
        self.hiddenPaths = hiddenPaths
        self.knownCandidatePaths = knownCandidatePaths
        self.includeShallowScan = includeShallowScan
        self.shallowScanRelativeRoots = shallowScanRelativeRoots
        self.shallowScanMaxDepth = shallowScanMaxDepth
    }
}
