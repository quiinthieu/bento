import BentoCore
import BentoFixes
import BentoHygiene
import BentoLogIngest
import BentoMCPProbe
import BentoScanner
import BentoStore
import BentoTokenizer
import Foundation
import Observation

/// Top-level sidebar navigation destinations (`PLAN.md` §6.7).
public enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
    case overview
    case repos
    case agents
    case findings
    case usage
    case fixHistory
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview:
            return "Overview"
        case .repos:
            return "Repos"
        case .agents:
            return "Agents"
        case .findings:
            return "Findings"
        case .usage:
            return "Usage"
        case .fixHistory:
            return "Fix History"
        case .settings:
            return "Settings"
        }
    }

    public var symbolName: String {
        switch self {
        case .overview:
            return "square.grid.2x2"
        case .repos:
            return "folder"
        case .agents:
            return "cpu"
        case .findings:
            return "checkmark.shield"
        case .usage:
            return "chart.bar.xaxis"
        case .fixHistory:
            return "clock.arrow.circlepath"
        case .settings:
            return "gearshape"
        }
    }

    public var shortcutDigit: Character {
        switch self {
        case .overview:
            return "1"
        case .repos:
            return "2"
        case .agents:
            return "3"
        case .findings:
            return "4"
        case .usage:
            return "5"
        case .fixHistory:
            return "6"
        case .settings:
            return "7"
        }
    }
}

/// Tabs inside the Repository Detail view (`PLAN.md` §6.7).
public enum RepoDetailTab: String, CaseIterable, Identifiable, Sendable {
    case budget
    case resolution
    case usage
    case hygiene

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .budget:
            return "Budget"
        case .resolution:
            return "Resolution"
        case .usage:
            return "Usage"
        case .hygiene:
            return "Hygiene"
        }
    }

    public var symbolName: String {
        switch self {
        case .budget:
            return "chart.bar.doc.horizontal"
        case .resolution:
            return "list.number"
        case .usage:
            return "waveform.path.ecg"
        case .hygiene:
            return "sparkles"
        }
    }
}

/// Sort criteria for repository and global usage tables (`PLAN.md` §6.7).
public enum UsageSortOrder: String, CaseIterable, Identifiable, Sendable {
    case costTimesUnused
    case tokensPerSession
    case invocations
    case name

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .costTimesUnused:
            return "Cost × Unused"
        case .tokensPerSession:
            return "Tokens / Session"
        case .invocations:
            return "Invocations"
        case .name:
            return "Name"
        }
    }
}

/// Overview ranking entry for the highest pre-prompt context token consumers.
public struct BudgetConsumerSummary: Sendable, Identifiable, Hashable {
    public var id: String
    public var repoPath: String
    public var repoName: String
    public var agent: AgentID
    public var item: BudgetItem
    public var repoPrePromptTotal: Int
}

/// Single 1-based physical line (or omission marker when `isOmissionMarker == true`) inside a hygiene span excerpt.
public struct SpanLine: Sendable, Identifiable, Hashable {
    public var id: Int { lineNumber }
    public var lineNumber: Int
    public var text: String
    public var isHighlighted: Bool
    public var isOmissionMarker: Bool

    public init(
        lineNumber: Int,
        text: String,
        isHighlighted: Bool,
        isOmissionMarker: Bool = false
    ) {
        self.lineNumber = lineNumber
        self.text = text
        self.isHighlighted = isHighlighted
        self.isOmissionMarker = isOmissionMarker
    }
}

/// Read-only source excerpt rendered side-by-side for multi-span hygiene findings (`PLAN.md` §6.7).
public struct SpanExcerpt: Sendable, Identifiable, Hashable {
    public var id: String
    public var location: SourceLocation
    public var displayPath: String
    public var lineRangeLabel: String
    public var lines: [SpanLine]
}

/// State backing the modal Fix Preview & Unified Diff sheet (`PLAN.md` §6.6, §6.7).
public struct ActiveFixSheetState: Sendable, Identifiable, Hashable {
    public var id: String { plan.id }
    public var request: FixRequest
    public var plan: FixPlan
    public var diffs: [UnifiedDiff]
    public var backupDirectoryPreviewPath: String
}

/// Discovered MCP server row surfaced in Settings for explicit per-server consent & probing (`PLAN.md` §6.4, §7).
public struct MCPServerInventoryEntry: Sendable, Identifiable, Hashable {
    public var id: String { "\(agent.rawValue):\(configHash):\(artifact.id.rawValue)" }
    public var configHash: String
    public var serverName: String
    public var agent: AgentID
    public var artifact: Artifact
    public var config: MCPServerConfig
    public var repoPath: String?
    public var hasConsent: Bool
    public var cachedProbe: MCPProbeRecord?
}

/// Detail selection displayed in the right-hand `NavigationSplitView` inspector column.
public enum InspectorSelection: Sendable, Hashable {
    case none
    case artifact(ArtifactID)
    case budgetItem(BudgetItem, AgentID)
    case finding(String)
    case usageItem(ArtifactUsageJoin)
    case fixJournal(String)
}

/// Primary `@MainActor` observable application coordinator for the macOS SwiftUI app (`PLAN.md` §6.7, §7, §11 T15).
///
/// Enforces read-only defaults: `"Allow changes"` starts `false`, MCP servers are never probed without
/// explicit per-hash consent, and API keys live exclusively in `APIKeyProviding` (Keychain in production).
@MainActor
@Observable
public final class BentoAppModel {
    /// Default maximum number of physical lines rendered per span excerpt before omitting middle lines.
    public static let defaultMaxLinesPerSpan = 18
    /// Default number of span locations rendered inline on a `FindingCardView` before disclosure expansion.
    public static let defaultInlineSpanLimit = 4

    private static let onboardingCompletedSettingKey = "ui.onboardingCompleted"
    private static let shallowScanRootsSettingKey = "ui.shallowScanRoots"
    private static let includeShallowScanSettingKey = "ui.includeShallowScan"
    private static let manualRepoPathsSettingKey = "ui.manualRepoPaths"
    private static let retentionDaysSettingKey = "ui.retentionDays"
    private static let unusedWindowDaysSettingKey = "ui.unusedWindowDays"
    private static let unusedMinSessionsSettingKey = "ui.unusedMinSessions"
    private static let anthropicAPIEnabledSettingKey = "tokenizer.api.anthropic.enabled"
    private static let geminiAPIEnabledSettingKey = "tokenizer.api.gemini.enabled"
    private static let automaticUpdatesSettingKey = "updates.automaticallyChecks"
    private static let debugProductNameSettingKey = "debug.productNameOverride"

    private struct SpanExcerptCacheKey: Hashable {
        var findingID: String
        var totalSpanCount: Int
        var firstSpanPath: String
        var contextLines: Int
        var maxSpans: Int
        var maxLinesPerSpan: Int
    }

    public let environment: AgentEnvironment
    public let store: BentoStore
    public let supportDirectory: URL
    public let workspace: Workspace
    private let fixEngine: any FixApplying
    private let apiKeyStore: any APIKeyProviding
    private let externalActions: any ExternalActionHandling
    private let updater: any AppUpdaterProviding
    private let cliInstaller: any CLIInstalling
    private let urlSessionOverride: URLSession?
    private var mcpConsentStore: MCPConsentStore
    private var confirmedAPICounters: [AgentID: any ExactAPITokenCounting] = [:]
    private var deltaSubscriptionTask: Task<Void, Never>?
    private var coalescedLogDeltaTask: Task<Void, Never>?
    private var explicitRefreshDepth: Int = 0
    private var derivedRebuildGeneration: Int = 0
    private var lastHandledSnapshotID: String?
    private var lastRawHygieneFindings: [Finding]?
    private var cachedPhysicalLinesByPath: [String: [String]] = [:]
    private var unreadableSpanPaths: Set<String> = []
    private var cachedSpanExcerpts: [SpanExcerptCacheKey: [SpanExcerpt]] = [:]

    // MARK: - Navigation & Chrome State

    public var selectedSection: SidebarSection = .overview
    public var selectedRepoPath: String?
    public var selectedRepoAgent: AgentID = .claudeCode
    public var selectedRepoTab: RepoDetailTab = .budget
    public var repoSearchQuery: String = ""
    public var usageSortOrder: UsageSortOrder = .costTimesUnused
    public var inspectorSelection: InspectorSelection = .none
    public var isInspectorPresented: Bool = true
    public var findingsKindFilter: Finding.Kind? = nil
    public var findingsSeverityFilter: Severity? = nil
    public var expandedFindingSpanIDs: Set<String> = []
    public var agentsFilter: AgentID? = nil
    public var settingsManualRepoDraft: String = ""
    public var settingsAnthropicKeyDraft: String = ""
    public var settingsGeminiKeyDraft: String = ""
    public var isConfirmingDeleteAllData: Bool = false
    public var isSendingTokenCountPreview: Bool = false
    public var selectedCLIInstallPreset: CLIInstallDestinationPreset = .userLocalBin
    public var isShowingInstallCLIConfirmation: Bool = false
    private var cliStatusRevision: Int = 0

    // MARK: - Modals, Banners & Alerts

    public var isShowingOnboarding: Bool
    public var activeFixSheet: ActiveFixSheetState?
    public var activeTokenCountPreview: TokenCountRequestPreview?
    public var pendingForceUndoEntry: FixJournalEntry?
    public var isRefreshing: Bool = false
    public var lastErrorMessage: String?
    public var statusBannerMessage: String?

    // MARK: - Workspace Data

    public private(set) var snapshot: Snapshot?
    public private(set) var repositories: [DiscoveredRepo] = []
    public private(set) var totalArtifactCount: Int = 0
    public private(set) var persistedFindings: [PersistedFinding] = []
    public private(set) var allFindings: [Finding] = []
    public private(set) var errorFindingCount: Int = 0
    public private(set) var warningFindingCount: Int = 0
    public private(set) var repoBudgetsByPath: [String: [AgentID: Budget]] = [:]
    public private(set) var biggestBudgetConsumers: [BudgetConsumerSummary] = []
    public private(set) var repoUsageByPath: [String: [ArtifactUsageJoin]] = [:]
    public private(set) var globalUsageItems: [ArtifactUsageJoin] = []
    public private(set) var unusedGlobalUsageCount: Int = 0
    public private(set) var globalUsageSummary: UsageSummary?
    public private(set) var fixHistory: [FixJournalEntry] = []
    public private(set) var mcpServerEntries: [MCPServerInventoryEntry] = []
    public private(set) var tccNotices: [TCCDenialNotice] = []
    private var artifactsIndex: [ArtifactID: Artifact] = [:]
    private var artifactsByAgent: [AgentID: [Artifact]] = [:]

    // MARK: - Persisted Settings State

    public private(set) var allowChanges: Bool = false
    public var shallowScanRootsText: String = RepoDiscoveryOptions.defaultShallowScanRelativeRoots.joined(
        separator: ", "
    )
    public var includeShallowScan: Bool = true
    public private(set) var manualRepoPaths: [String] = []
    public var retentionDays: Int = BentoStore.defaultRetentionDays
    public var unusedWindowDays: Int = UsageJoinEngine.defaultWindowDays
    public var unusedMinimumSessions: Int = UsageJoinEngine.defaultMinimumSessions
    public var canonicalSkillsDirectory: String = ""
    public private(set) var anthropicCountAPIEnabled: Bool = false
    public private(set) var geminiCountAPIEnabled: Bool = false
    public private(set) var automaticallyChecksForUpdates: Bool = false
    private var apiKeyPresenceVersion: Int = 0

    #if DEBUG
        public var debugProductNameOverride: String = ""
    #endif

    // MARK: - Initializers

    /// Constructs a live or `-fixtureHome` application model from parsed launch options.
    public convenience init(
        launchConfiguration: LaunchConfiguration? = nil,
        apiKeyStore: (any APIKeyProviding)? = nil,
        externalActions: (any ExternalActionHandling)? = nil,
        updater: (any AppUpdaterProviding)? = nil,
        cliInstaller: (any CLIInstalling)? = nil,
        urlSessionOverride: URLSession? = nil,
        enableLiveWatching: Bool = false
    ) throws {
        let launch = try launchConfiguration ?? LaunchConfiguration.parse()
        let processEnv = ProcessInfo.processInfo.environment
        var mergedEnv: [String: String]
        if launch.isFixtureMode {
            mergedEnv = processEnv.filter { $0.key.hasPrefix("BENTO_") }
            mergedEnv["HOME"] = launch.homeURL.path
        } else {
            mergedEnv = processEnv
        }
        for (key, value) in launch.environmentOverrides {
            mergedEnv[key] = value
        }

        let fixedNow: Date?
        if let rawNow = mergedEnv["BENTO_NOW_ISO8601"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawNow.isEmpty
        {
            fixedNow = ISO8601DateFormatter().date(from: rawNow)
        } else {
            fixedNow = nil
        }

        let env = AgentEnvironment(
            home: launch.homeURL,
            env: mergedEnv,
            fileSystem: LocalReadOnlyFileSystem(),
            now: { fixedNow ?? Date() }
        )

        let resolvedStore: BentoStore
        let supportDir: URL
        if launch.isFixtureMode && launch.supportDirectoryOverride == nil {
            resolvedStore = try BentoStore.inMemory()
            supportDir =
                launch.homeURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent(Product.supportDirName, isDirectory: true)
                .standardizedFileURL
        } else {
            supportDir =
                launch.supportDirectoryOverride
                ?? launch.homeURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent(Product.supportDirName, isDirectory: true)
                .standardizedFileURL
            resolvedStore = try BentoStore(
                databaseURL: supportDir.appendingPathComponent("bento.sqlite", isDirectory: false)
            )
        }

        let engine = FixEngine(
            homeURL: launch.homeURL,
            supportDirectory: supportDir,
            store: resolvedStore,
            fileSystem: env.fileSystem
        )

        let showOnboarding: Bool
        if launch.forceShowOnboarding {
            showOnboarding = true
        } else if launch.skipOnboarding {
            showOnboarding = false
        } else {
            let completed = (try? resolvedStore.setting(Bool.self, forKey: Self.onboardingCompletedSettingKey)) ?? false
            showOnboarding = !completed
        }

        self.init(
            environment: env,
            store: resolvedStore,
            supportDirectory: supportDir,
            fixEngine: engine,
            apiKeyStore: apiKeyStore ?? KeychainAPIKeyStore(),
            externalActions: externalActions,
            updater: updater,
            cliInstaller: cliInstaller,
            urlSessionOverride: urlSessionOverride,
            showOnboardingOnFirstRun: showOnboarding,
            enableLiveWatching: enableLiveWatching && !launch.isFixtureMode
        )
    }

    /// Designated initializer supporting injected `BentoStore`, `FixApplying` spies, and hermetic mocks.
    public init(
        environment: AgentEnvironment,
        store: BentoStore,
        supportDirectory: URL,
        fixEngine: any FixApplying,
        apiKeyStore: any APIKeyProviding = KeychainAPIKeyStore(),
        externalActions: (any ExternalActionHandling)? = nil,
        updater: (any AppUpdaterProviding)? = nil,
        cliInstaller: (any CLIInstalling)? = nil,
        urlSessionOverride: URLSession? = nil,
        showOnboardingOnFirstRun: Bool = false,
        enableLiveWatching: Bool = false
    ) {
        self.environment = environment
        self.store = store
        self.supportDirectory = supportDirectory.standardizedFileURL
        self.fixEngine = fixEngine
        self.apiKeyStore = apiKeyStore
        self.externalActions = externalActions ?? WorkspaceExternalActionHandler()
        self.updater = updater ?? DisabledAppUpdater()
        self.cliInstaller = cliInstaller ?? CLIInstaller()
        self.urlSessionOverride = urlSessionOverride
        self.isShowingOnboarding = showOnboardingOnFirstRun
        self.mcpConsentStore = (try? MCPConsentStore(persistence: store)) ?? (try! MCPConsentStore())

        let initialOptions = Self.loadRepoDiscoveryOptions(from: store)
        let watcher: (any FileWatcher)? = enableLiveWatching ? FSEventsFileWatcher() : nil
        self.workspace = Workspace(
            environment: environment,
            store: store,
            watcher: watcher,
            repoDiscoveryOptions: initialOptions
        )

        loadPersistedSettings()

        if enableLiveWatching {
            startLiveWatchSubscription()
        }
    }

    // MARK: - Computed Properties

    public var effectiveProductName: String {
        #if DEBUG
            let trimmed = debugProductNameOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        #endif
        return Product.name
    }

    public var detectedAgentCount: Int {
        guard let snapshot else { return 0 }
        return snapshot.detections.values.filter(\.isDetected).count
    }

    public func artifacts(for agent: AgentID) -> [Artifact] {
        artifactsByAgent[agent] ?? []
    }

    public var filteredRepositories: [DiscoveredRepo] {
        let query = repoSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = repositories.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            if lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) != .orderedSame {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            return lhs.path < rhs.path
        }
        guard !query.isEmpty else { return base }
        return base.filter { repo in
            repo.displayName.lowercased().contains(query) || repo.path.lowercased().contains(query)
        }
    }

    public var selectedRepository: DiscoveredRepo? {
        guard let selectedRepoPath else { return nil }
        return repositories.first { $0.path == selectedRepoPath }
    }

    public var currentRepoBudgetsByAgent: [AgentID: Budget] {
        guard let selectedRepoPath else { return [:] }
        return repoBudgetsByPath[selectedRepoPath] ?? [:]
    }

    public var currentRepoBudget: Budget? {
        currentRepoBudgetsByAgent[selectedRepoAgent]
    }

    public var currentRepoChartSummaries: [BudgetChartSummary] {
        let map = currentRepoBudgetsByAgent
        return workspace.budgetCapableAgents().compactMap { agent in
            guard let budget = map[agent] else { return nil }
            return BudgetChartSummary.build(from: budget)
        }
    }

    public var currentRepoResolution: Resolution? {
        guard let snapshot, let selectedRepoPath else { return nil }
        return snapshot.resolution(for: selectedRepoAgent, repoPath: selectedRepoPath)
    }

    public var currentRepoArtifactsForSelectedAgent: [Artifact] {
        guard let snapshot, let selectedRepoPath else { return [] }
        return snapshot.artifacts(agent: selectedRepoAgent, repoPath: selectedRepoPath)
    }

    public var currentRepoUsageItems: [ArtifactUsageJoin] {
        guard let selectedRepoPath else { return [] }
        let items = repoUsageByPath[selectedRepoPath] ?? []
        if selectedRepoAgent.supportsFullBudgetAndUsage {
            return items.filter { $0.agent == selectedRepoAgent }
        }
        return []
    }

    public var sortedRepoUsageItems: [ArtifactUsageJoin] {
        Self.sortUsageItems(currentRepoUsageItems, by: usageSortOrder)
    }

    public var sortedGlobalUsageItems: [ArtifactUsageJoin] {
        Self.sortUsageItems(globalUsageItems, by: usageSortOrder)
    }

    public var currentRepoFindings: [Finding] {
        guard let snapshot, let selectedRepoPath else { return [] }
        let canonical = snapshot.resolveCanonicalRepoPath(selectedRepoPath)
        let repoArtifacts = snapshot.artifacts(agent: nil, repoPath: canonical)
        let repoArtifactIDs = Set(repoArtifacts.map(\.id))
        let agentArtifactIDs = Set(repoArtifacts.filter { $0.agent == selectedRepoAgent }.map(\.id))

        return allFindings.filter { finding in
            let matchesRepo =
                finding.artifacts.contains(where: { repoArtifactIDs.contains($0) })
                || finding.spans.contains(where: { $0.path.hasPrefix(canonical + "/") || $0.path == canonical })
            guard matchesRepo else { return false }
            if finding.artifacts.isEmpty {
                return true
            }
            return finding.artifacts.contains(where: { agentArtifactIDs.contains($0) })
        }
    }

    public var canApplyActiveFix: Bool {
        allowChanges && activeFixSheet != nil
    }

    // MARK: - Refresh Pipeline

    private struct DerivedRebuildInput: Sendable {
        var activeSnapshot: Snapshot
        var updatedRepos: [DiscoveredRepo]
        var runLogIngest: Bool
        var reusedHygieneFindings: [Finding]?
        var environment: AgentEnvironment
        var store: BentoStore
        var workspace: Workspace
        var retentionDays: Int
        var unusedWindowDays: Int
        var unusedMinimumSessions: Int
        var anthropicCountAPIEnabled: Bool
        var geminiCountAPIEnabled: Bool
        var confirmedAPICounters: [AgentID: any ExactAPITokenCounting]
        var productName: String
    }

    private struct DerivedRebuildOutput: Sendable {
        var mcpConsentStore: MCPConsentStore?
        var globalUsageSummary: UsageSummary?
        var repoBudgetsByPath: [String: [AgentID: Budget]]
        var biggestBudgetConsumers: [BudgetConsumerSummary]
        var repoUsageByPath: [String: [ArtifactUsageJoin]]
        var globalUsageItems: [ArtifactUsageJoin]
        var unusedGlobalUsageCount: Int
        var rawHygieneFindings: [Finding]
        var persistedFindings: [PersistedFinding]
        var allFindings: [Finding]
        var fixHistory: [FixJournalEntry]
        var mcpServerEntries: [MCPServerInventoryEntry]
        var tccNotices: [TCCDenialNotice]
    }

    /// Executes a full scan, incremental log ingest, calibration fit, budget computation, usage join, and hygiene audit.
    public func refreshAll() async {
        coalescedLogDeltaTask?.cancel()
        coalescedLogDeltaTask = nil
        explicitRefreshDepth += 1
        isRefreshing = true
        lastErrorMessage = nil
        defer {
            explicitRefreshDepth = max(0, explicitRefreshDepth - 1)
            isRefreshing = explicitRefreshDepth > 0
        }

        do {
            await workspace.setRepoDiscoveryOptions(buildCurrentRepoDiscoveryOptions())
            let scannedSnapshot = try await workspace.scanFull()
            lastHandledSnapshotID = scannedSnapshot.id
            try await rebuildDerivedState(
                from: scannedSnapshot,
                runLogIngest: true,
                reusedHygieneFindings: nil
            )
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func applyImmediateSnapshotState(_ activeSnapshot: Snapshot) -> [DiscoveredRepo] {
        self.snapshot = activeSnapshot
        self.lastHandledSnapshotID = activeSnapshot.id
        clearExcerptCaches()

        let allArtifacts = activeSnapshot.artifacts
        self.totalArtifactCount = allArtifacts.count

        var index: [ArtifactID: Artifact] = [:]
        index.reserveCapacity(allArtifacts.count)
        var byAgent: [AgentID: [Artifact]] = [:]
        for art in allArtifacts {
            index[art.id] = art
            byAgent[art.agent, default: []].append(art)
        }
        self.artifactsIndex = index
        self.artifactsByAgent = byAgent

        let pinnedPaths = (try? store.pinnedRepoPaths()) ?? []
        var updatedRepos = activeSnapshot.repos
        for idx in updatedRepos.indices where pinnedPaths.contains(updatedRepos[idx].path) {
            updatedRepos[idx].isPinned = true
        }
        self.repositories = updatedRepos

        if selectedRepoPath == nil || !updatedRepos.contains(where: { $0.path == selectedRepoPath }) {
            selectedRepoPath = updatedRepos.first?.path
        }

        return updatedRepos
    }

    private func rebuildDerivedState(
        from activeSnapshot: Snapshot,
        runLogIngest: Bool,
        reusedHygieneFindings: [Finding]? = nil
    ) async throws {
        derivedRebuildGeneration &+= 1
        let generation = derivedRebuildGeneration
        let updatedRepos = applyImmediateSnapshotState(activeSnapshot)

        let input = DerivedRebuildInput(
            activeSnapshot: activeSnapshot,
            updatedRepos: updatedRepos,
            runLogIngest: runLogIngest,
            reusedHygieneFindings: reusedHygieneFindings,
            environment: environment,
            store: store,
            workspace: workspace,
            retentionDays: retentionDays,
            unusedWindowDays: unusedWindowDays,
            unusedMinimumSessions: unusedMinimumSessions,
            anthropicCountAPIEnabled: anthropicCountAPIEnabled,
            geminiCountAPIEnabled: geminiCountAPIEnabled,
            confirmedAPICounters: confirmedAPICounters,
            productName: effectiveProductName
        )

        let output = try await Task.detached(priority: .userInitiated) {
            try await Self.computeDerivedWorkspaceState(input)
        }.value

        guard generation == derivedRebuildGeneration else {
            return
        }

        if let refreshedConsentStore = output.mcpConsentStore {
            self.mcpConsentStore = refreshedConsentStore
        }
        self.globalUsageSummary = output.globalUsageSummary
        self.repoBudgetsByPath = output.repoBudgetsByPath
        self.biggestBudgetConsumers = output.biggestBudgetConsumers
        self.repoUsageByPath = output.repoUsageByPath
        self.globalUsageItems = output.globalUsageItems
        self.unusedGlobalUsageCount = output.unusedGlobalUsageCount
        self.lastRawHygieneFindings = output.rawHygieneFindings
        self.persistedFindings = output.persistedFindings
        self.allFindings = output.allFindings
        updateFindingCounts()
        self.fixHistory = output.fixHistory
        self.mcpServerEntries = output.mcpServerEntries
        self.tccNotices = output.tccNotices
    }

    nonisolated private static func computeDerivedWorkspaceState(
        _ input: DerivedRebuildInput
    ) async throws -> DerivedRebuildOutput {
        let activeSnapshot = input.activeSnapshot
        let updatedRepos = input.updatedRepos
        let environment = input.environment
        let store = input.store
        let workspace = input.workspace

        // 1. Incremental log ingest + retention pruning when requested.
        var logDiagnostics: [Diagnostic] = []
        if input.runLogIngest {
            try store.syncDiscoveredRepos(updatedRepos, seenAt: environment.now())
            let logTargets = try await workspace.logIngestTargets(for: nil)
            let ingestReport = try await LogIngestor(
                fileSystem: environment.fileSystem,
                store: store
            ).ingest(targets: logTargets)
            logDiagnostics = ingestReport.diagnostics

            if input.retentionDays > 0 {
                let cutoff = environment.now().addingTimeInterval(-Double(input.retentionDays) * 86_400.0)
                _ = try? store.pruneUsageEvents(olderThan: cutoff)
            }
        }

        // 2. Collect MCP probe cache & consent status.
        let refreshedConsentStore = try? MCPConsentStore(persistence: store)
        let consentedHashes = refreshedConsentStore?.allConsentedHashes ?? []
        var probesByHash: [String: MCPProbeRecord] = [:]
        let allProbes = (try? store.allMCPProbes()) ?? []
        for probe in allProbes where probe.ok {
            probesByHash[probe.serverConfigHash] = probe
        }
        let fallbackEstimate = try? store.mcpFallbackEstimate()

        // 3. Fit calibrations from local session logs if >= 3 samples exist.
        let uncalibratedTokenizer = try AgentTokenizerRegistry()
        let sessions = (try? store.calibrationSessions(agent: nil)) ?? []
        if sessions.count >= CalibrationFitter.defaultMinimumSamples {
            let fitted = await Self.fitCalibrations(
                sessions: sessions,
                workspace: workspace,
                uncalibratedTokenizer: uncalibratedTokenizer,
                probesByHash: probesByHash,
                fallbackEstimate: fallbackEstimate,
                fileSystem: environment.fileSystem,
                now: environment.now()
            )
            if !fitted.isEmpty {
                try? store.upsertCalibrations(fitted)
            }
        }

        var tokenizer = uncalibratedTokenizer
        let calibrations = (try? store.calibrations(for: nil)) ?? []
        if !calibrations.isEmpty {
            tokenizer.applyCalibrations(calibrations)
        }
        if input.anthropicCountAPIEnabled, let counter = input.confirmedAPICounters[.claudeCode] {
            tokenizer.setExactAPICounter(counter, for: .claudeCode)
        }
        if input.geminiCountAPIEnabled, let counter = input.confirmedAPICounters[.gemini] {
            tokenizer.setExactAPICounter(counter, for: .gemini)
        }

        // 4. Compute per-repo budgets & usage joins across budget-capable agents.
        let now = environment.now()
        let windowDays = max(1, input.unusedWindowDays)
        let minSessions = max(1, input.unusedMinimumSessions)
        let since = now.addingTimeInterval(-Double(windowDays) * 86_400.0)
        let hasFixedClock = !(environment.env["BENTO_NOW_ISO8601"] ?? "").isEmpty
        let until = hasFixedClock ? now : max(now, now.addingTimeInterval(86_400.0 * 3650.0))

        let globalUsageSummary = try? store.usageSummary(
            since: since,
            until: until,
            agent: nil,
            repoPath: nil
        )

        let budgetAgents = workspace.budgetCapableAgents()
        let joinEngine = UsageJoinEngine()
        var budgetsMap: [String: [AgentID: Budget]] = [:]
        var usageByRepo: [String: [ArtifactUsageJoin]] = [:]
        var allUsageItems: [ArtifactUsageJoin] = []
        var unusedFindings: [Finding] = []
        var seenUnusedFindingIDs: Set<String> = []

        for repo in updatedRepos {
            let repoURL = URL(fileURLWithPath: repo.path).standardizedFileURL
            guard environment.fileSystem.exists(repoURL) else { continue }

            let repoUsageSummary = try? store.usageSummary(
                since: since,
                until: until,
                agent: nil,
                repoPath: repo.path
            )
            let usageByAgent = Dictionary(
                uniqueKeysWithValues: (repoUsageSummary?.byAgent ?? []).map { ($0.agent, $0) }
            )

            var perAgentBudgets: [AgentID: Budget] = [:]
            var joinInputs: [UsageJoinAgentInput] = []

            for agent in budgetAgents {
                let measured =
                    (try? store.measuredFirstTurnMedianInput(
                        agent: agent,
                        repoPath: repoURL.path,
                        model: nil
                    )) ?? usageByAgent[agent]?.firstTurnMedianInput

                guard
                    let (artifacts, resolution) = try? await workspace.resolvedContext(
                        for: agent,
                        folder: repoURL
                    ),
                    let computedBudget = try? await workspace.budget(
                        for: agent,
                        folder: repoURL,
                        tokenizer: tokenizer,
                        mcpProbesByConfigHash: probesByHash,
                        mcpFallbackEstimate: fallbackEstimate,
                        measuredFirstTurnInput: measured
                    )
                else {
                    continue
                }

                perAgentBudgets[agent] = computedBudget
                try? store.saveBudget(computedBudget, snapshotID: activeSnapshot.id)

                joinInputs.append(
                    UsageJoinAgentInput(
                        agent: agent,
                        artifacts: artifacts,
                        resolution: resolution,
                        budget: computedBudget,
                        fixSupport: workspace.fixSupport(for: agent),
                        usage: usageByAgent[agent]
                    )
                )
            }

            budgetsMap[repo.path] = perAgentBudgets

            let joinReport = joinEngine.join(
                repoPath: repo.path,
                windowDays: windowDays,
                since: since,
                until: now,
                minimumSessions: minSessions,
                inputs: joinInputs
            )
            usageByRepo[repo.path] = joinReport.items
            allUsageItems.append(contentsOf: joinReport.items)
            for finding in joinReport.unusedFindings where seenUnusedFindingIDs.insert(finding.id).inserted {
                unusedFindings.append(finding)
            }
        }

        let biggestConsumers = Self.computeBiggestBudgetConsumers(
            repositories: updatedRepos,
            repoBudgetsByPath: budgetsMap
        )
        let unusedGlobalCount = allUsageItems.reduce(into: 0) { count, item in
            if item.costTimesUnusedScore > 0 {
                count += 1
            }
        }

        // 5. Run HygieneEngine across the snapshot (or reuse cached findings on pure log-only updates).
        let hygieneFindings: [Finding]
        if let reused = input.reusedHygieneFindings {
            hygieneFindings = reused
        } else {
            hygieneFindings = try HygieneEngine().audit(
                snapshot: activeSnapshot,
                fixSupports: workspace.allFixSupports(),
                fileSystem: environment.fileSystem,
                tokenizer: tokenizer
            )
        }

        var combinedFindings = hygieneFindings
        let existingIDs = Set(hygieneFindings.map(\.id))
        for unused in unusedFindings where !existingIDs.contains(unused.id) {
            combinedFindings.append(unused)
        }
        try? store.saveFindings(combinedFindings, snapshotID: activeSnapshot.id)

        let storedFindings = (try? store.fetchPersistedFindings(snapshotID: activeSnapshot.id)) ?? []
        let resolvedPersisted: [PersistedFinding]
        let resolvedActiveFindings: [Finding]
        if storedFindings.isEmpty && !combinedFindings.isEmpty {
            resolvedPersisted = combinedFindings.map {
                PersistedFinding(snapshotID: activeSnapshot.id, finding: $0, isDismissed: false)
            }
            resolvedActiveFindings = combinedFindings
        } else {
            resolvedPersisted = storedFindings
            resolvedActiveFindings = storedFindings.filter { !$0.isDismissed }.map(\.finding)
        }

        // 6. Refresh Fix History, MCP server inventory, and TCC notices.
        let fixHistory = (try? store.fetchFixJournalEntries(limit: 200)) ?? []
        let mcpServerEntries = Self.buildMCPServerInventoryList(
            from: activeSnapshot,
            probes: allProbes,
            consentedHashes: consentedHashes
        )

        var allDiagnostics: [Diagnostic] = logDiagnostics
        for art in activeSnapshot.artifacts {
            allDiagnostics.append(contentsOf: art.diagnostics)
        }
        for res in activeSnapshot.resolutions {
            allDiagnostics.append(contentsOf: res.warnings)
        }
        let tccNotices = TCCDenialDetector.detect(
            from: allDiagnostics,
            homePath: activeSnapshot.homePath,
            productName: input.productName
        )

        return DerivedRebuildOutput(
            mcpConsentStore: refreshedConsentStore,
            globalUsageSummary: globalUsageSummary,
            repoBudgetsByPath: budgetsMap,
            biggestBudgetConsumers: biggestConsumers,
            repoUsageByPath: usageByRepo,
            globalUsageItems: allUsageItems,
            unusedGlobalUsageCount: unusedGlobalCount,
            rawHygieneFindings: hygieneFindings,
            persistedFindings: resolvedPersisted,
            allFindings: resolvedActiveFindings,
            fixHistory: fixHistory,
            mcpServerEntries: mcpServerEntries,
            tccNotices: tccNotices
        )
    }

    nonisolated private static func computeBiggestBudgetConsumers(
        repositories: [DiscoveredRepo],
        repoBudgetsByPath: [String: [AgentID: Budget]]
    ) -> [BudgetConsumerSummary] {
        var consumers: [BudgetConsumerSummary] = []
        let repoNamesByPath = Dictionary(uniqueKeysWithValues: repositories.map { ($0.path, $0.displayName) })

        for (repoPath, byAgent) in repoBudgetsByPath {
            let repoName = repoNamesByPath[repoPath] ?? URL(fileURLWithPath: repoPath).lastPathComponent
            for (agent, budget) in byAgent {
                let preTotal = budget.prePromptTokens
                for (index, item) in budget.items.enumerated()
                where item.countsTowardPrePrompt && item.tokens > 0
                    && item.category != .builtInSystem && item.category != .builtInTools
                {
                    consumers.append(
                        BudgetConsumerSummary(
                            id: "\(repoPath):\(agent.rawValue):\(index):\(item.label)",
                            repoPath: repoPath,
                            repoName: repoName,
                            agent: agent,
                            item: item,
                            repoPrePromptTotal: preTotal
                        )
                    )
                }
            }
        }

        return consumers.sorted { lhs, rhs in
            if lhs.item.tokens != rhs.item.tokens {
                return lhs.item.tokens > rhs.item.tokens
            }
            if lhs.agent != rhs.agent {
                return lhs.agent < rhs.agent
            }
            return lhs.item.label < rhs.item.label
        }
    }

    // MARK: - Navigation & Keyboard Actions

    public func selectRepository(_ path: String?) async {
        selectedRepoPath = path
        if path != nil {
            selectedSection = .repos
        }
    }

    public func togglePinRepository(path: String) async throws {
        let currentPinned = repositories.first(where: { $0.path == path })?.isPinned ?? false
        let newPinned = !currentPinned
        let displayName = repositories.first(where: { $0.path == path })?.displayName
        try store.setRepoPinned(
            path: path,
            pinned: newPinned,
            displayName: displayName,
            now: environment.now()
        )
        for idx in repositories.indices where repositories[idx].path == path {
            repositories[idx].isPinned = newPinned
        }
        await workspace.setRepoDiscoveryOptions(buildCurrentRepoDiscoveryOptions())
    }

    public func addManualRepository(path: String) async throws {
        let expanded = (path as NSString).expandingTildeInPath
        let stdPath = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
        guard !stdPath.isEmpty else { return }
        if !manualRepoPaths.contains(stdPath) {
            manualRepoPaths.append(stdPath)
            manualRepoPaths.sort()
            try store.setSetting(manualRepoPaths, forKey: Self.manualRepoPathsSettingKey)
        }
        await refreshAll()
        selectedRepoPath = stdPath
        selectedSection = .repos
    }

    public func removeManualRepository(path: String) async throws {
        manualRepoPaths.removeAll { $0 == path }
        try store.setSetting(manualRepoPaths, forKey: Self.manualRepoPathsSettingKey)
        await refreshAll()
    }

    public func completeOnboarding() {
        isShowingOnboarding = false
        try? store.setSetting(true, forKey: Self.onboardingCompletedSettingKey)
    }

    public func selectSectionByShortcut(index: Int) {
        let all = SidebarSection.allCases
        guard index >= 1 && index <= all.count else { return }
        selectedSection = all[index - 1]
    }

    public func selectNextRepository() {
        let list = filteredRepositories
        guard !list.isEmpty else { return }
        selectedSection = .repos
        guard let current = selectedRepoPath,
            let idx = list.firstIndex(where: { $0.path == current })
        else {
            selectedRepoPath = list[0].path
            return
        }
        let nextIndex = (idx + 1) % list.count
        selectedRepoPath = list[nextIndex].path
    }

    public func selectPreviousRepository() {
        let list = filteredRepositories
        guard !list.isEmpty else { return }
        selectedSection = .repos
        guard let current = selectedRepoPath,
            let idx = list.firstIndex(where: { $0.path == current })
        else {
            selectedRepoPath = list[list.count - 1].path
            return
        }
        let prevIndex = (idx - 1 + list.count) % list.count
        selectedRepoPath = list[prevIndex].path
    }

    public func cycleRepoTab(forward: Bool) {
        let tabs = RepoDetailTab.allCases
        guard let idx = tabs.firstIndex(of: selectedRepoTab) else { return }
        let next = forward ? (idx + 1) % tabs.count : (idx - 1 + tabs.count) % tabs.count
        selectedRepoTab = tabs[next]
    }

    public func cycleSelectedAgent(forward: Bool) {
        let agents = AgentID.allCases
        guard let idx = agents.firstIndex(of: selectedRepoAgent) else { return }
        let next = forward ? (idx + 1) % agents.count : (idx - 1 + agents.count) % agents.count
        selectedRepoAgent = agents[next]
    }

    // MARK: - Artifacts, Spans & External Actions

    public func artifact(for id: ArtifactID) -> Artifact? {
        artifactsIndex[id]
    }

    public func revealArtifactInFinder(_ artifact: Artifact) {
        revealPathInFinder(artifact.location.path)
    }

    public func openArtifactInEditor(_ artifact: Artifact) {
        openPathInEditor(artifact.location.path)
    }

    public func revealPathInFinder(_ path: String) {
        externalActions.revealInFinder(URL(fileURLWithPath: path))
    }

    public func openPathInEditor(_ path: String) {
        externalActions.openInEditor(URL(fileURLWithPath: path))
    }

    /// Extracts cached 1-based physical line excerpts for `finding.spans` (`PLAN.md` §6.7),
    /// optionally capping the number of inline spans and truncating multi-hundred-line spans.
    public func spanExcerpts(
        for finding: Finding,
        contextLines: Int = 2,
        maxSpans: Int? = nil,
        maxLinesPerSpan: Int = BentoAppModel.defaultMaxLinesPerSpan
    ) -> [SpanExcerpt] {
        guard !finding.spans.isEmpty else { return [] }

        let resolvedSpanLimit = maxSpans.map { max(1, min(finding.spans.count, $0)) } ?? finding.spans.count
        let resolvedLineCap = max(4, maxLinesPerSpan)
        let cacheKey = SpanExcerptCacheKey(
            findingID: finding.id,
            totalSpanCount: finding.spans.count,
            firstSpanPath: finding.spans[0].path,
            contextLines: contextLines,
            maxSpans: resolvedSpanLimit,
            maxLinesPerSpan: resolvedLineCap
        )
        if let cached = cachedSpanExcerpts[cacheKey] {
            return cached
        }

        var results: [SpanExcerpt] = []
        results.reserveCapacity(resolvedSpanLimit)

        for idx in 0..<resolvedSpanLimit {
            let span = finding.spans[idx]
            let physicalLines = loadCachedPhysicalLines(forPath: span.path)
            var excerptLines: [SpanLine] = []
            let rangeLabel: String

            if let physicalLines, !physicalLines.isEmpty {
                let totalCount = physicalLines.count
                if let lineRange = span.lineRange {
                    let lower = max(1, min(totalCount, lineRange.lowerBound))
                    let upper = max(lower, min(totalCount, lineRange.upperBound))
                    let start = max(1, lower - max(0, contextLines))
                    let end = min(totalCount, upper + max(0, contextLines))
                    rangeLabel = lower == upper ? "L\(lower)" : "L\(lower)–L\(upper)"
                    excerptLines = Self.buildBoundedSpanLines(
                        physicalLines: physicalLines,
                        start: start,
                        end: end,
                        highlightedRange: lower...upper,
                        maxLines: resolvedLineCap
                    )
                } else {
                    let end = min(totalCount, min(12, resolvedLineCap))
                    rangeLabel = "L1–L\(end)"
                    for lineNum in 1...end {
                        excerptLines.append(
                            SpanLine(
                                lineNumber: lineNum,
                                text: physicalLines[lineNum - 1],
                                isHighlighted: true
                            )
                        )
                    }
                }
            } else {
                rangeLabel = span.lineRange.map { "L\($0.lowerBound)–L\($0.upperBound)" } ?? "File"
                excerptLines = [SpanLine(lineNumber: 1, text: "(empty or unreadable file)", isHighlighted: false)]
            }

            results.append(
                SpanExcerpt(
                    id: "\(finding.id):span:\(idx):\(span.path)",
                    location: span,
                    displayPath: abbreviateHomePath(span.path),
                    lineRangeLabel: rangeLabel,
                    lines: excerptLines
                )
            )
        }

        cachedSpanExcerpts[cacheKey] = results
        return results
    }

    private func loadCachedPhysicalLines(forPath rawPath: String) -> [String]? {
        let fileURL = URL(fileURLWithPath: rawPath).standardizedFileURL
        let stdPath = fileURL.path
        if unreadableSpanPaths.contains(stdPath) {
            return nil
        }
        if let cached = cachedPhysicalLinesByPath[stdPath] {
            return cached
        }
        guard let data = try? environment.fileSystem.contents(at: fileURL) else {
            unreadableSpanPaths.insert(stdPath)
            return nil
        }
        let rawText = String(decoding: data, as: UTF8.self)
        if rawText.isEmpty {
            unreadableSpanPaths.insert(stdPath)
            return nil
        }
        let lines =
            rawText
            .components(separatedBy: "\n")
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        cachedPhysicalLinesByPath[stdPath] = lines
        return lines
    }

    public func isFindingSpansExpanded(_ findingID: String) -> Bool {
        expandedFindingSpanIDs.contains(findingID)
    }

    public func toggleFindingSpansExpanded(_ findingID: String) {
        if expandedFindingSpanIDs.contains(findingID) {
            expandedFindingSpanIDs.remove(findingID)
        } else {
            expandedFindingSpanIDs.insert(findingID)
        }
    }

    private static func buildBoundedSpanLines(
        physicalLines: [String],
        start: Int,
        end: Int,
        highlightedRange: ClosedRange<Int>,
        maxLines: Int
    ) -> [SpanLine] {
        let windowCount = end - start + 1
        guard windowCount > maxLines else {
            var lines: [SpanLine] = []
            lines.reserveCapacity(windowCount)
            for lineNum in start...end {
                lines.append(
                    SpanLine(
                        lineNumber: lineNum,
                        text: physicalLines[lineNum - 1],
                        isHighlighted: highlightedRange.contains(lineNum)
                    )
                )
            }
            return lines
        }

        let headCount = max(2, (maxLines * 2) / 3)
        let tailCount = max(2, maxLines - headCount)
        let headEnd = start + headCount - 1
        let tailStart = end - tailCount + 1
        let omittedCount = max(1, tailStart - headEnd - 1)

        var lines: [SpanLine] = []
        lines.reserveCapacity(headCount + tailCount + 1)
        for lineNum in start...headEnd {
            lines.append(
                SpanLine(
                    lineNumber: lineNum,
                    text: physicalLines[lineNum - 1],
                    isHighlighted: highlightedRange.contains(lineNum)
                )
            )
        }
        lines.append(
            SpanLine(
                lineNumber: 0,
                text: "… \(omittedCount) lines omitted …",
                isHighlighted: false,
                isOmissionMarker: true
            )
        )
        for lineNum in tailStart...end {
            lines.append(
                SpanLine(
                    lineNumber: lineNum,
                    text: physicalLines[lineNum - 1],
                    isHighlighted: highlightedRange.contains(lineNum)
                )
            )
        }
        return lines
    }

    private func clearExcerptCaches() {
        cachedPhysicalLinesByPath.removeAll(keepingCapacity: false)
        unreadableSpanPaths.removeAll(keepingCapacity: false)
        cachedSpanExcerpts.removeAll(keepingCapacity: false)
    }

    private func updateFindingCounts() {
        var errors = 0
        var warnings = 0
        for finding in allFindings {
            switch finding.severity {
            case .error:
                errors += 1
            case .warning:
                warnings += 1
            case .info:
                break
            }
        }
        errorFindingCount = errors
        warningFindingCount = warnings
    }

    public func toggleDismissFinding(_ finding: Finding, dismissed: Bool = true) {
        try? store.setFindingDismissed(id: finding.id, snapshotID: snapshot?.id, dismissed: dismissed)
        if let snapID = snapshot?.id,
            let refreshed = try? store.fetchPersistedFindings(snapshotID: snapID)
        {
            self.persistedFindings = refreshed
            self.allFindings = refreshed.filter { !$0.isDismissed }.map(\.finding)
        } else if dismissed {
            self.allFindings.removeAll { $0.id == finding.id }
        }
        updateFindingCounts()
    }

    // MARK: - Reversible Fixes & Master "Allow changes" Gate (`PLAN.md` §6.6, §6.7, §11 T15)

    public func setAllowChanges(_ enabled: Bool) throws {
        try store.setAllowChangesEnabled(enabled)
        self.allowChanges = enabled
    }

    public func openFixPreview(for request: FixRequest) throws {
        guard let snapshot else {
            throw BentoFixesError.targetNotFound("Workspace snapshot is not loaded yet.")
        }
        var adjustedRequest = request
        if adjustedRequest.canonicalSkillsRoot == nil {
            let trimmedCanonical = canonicalSkillsDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedCanonical.isEmpty {
                adjustedRequest.canonicalSkillsRoot = (trimmedCanonical as NSString).expandingTildeInPath
            }
        }
        // Planning in UI preview is read-only; confirmation happens explicitly via the Fix sheet's Apply button.
        if adjustedRequest.kind == .trashArtifact {
            adjustedRequest.confirmed = true
        }

        let plan = try fixEngine.plan(
            adjustedRequest,
            snapshot: snapshot,
            fixSupports: workspace.allFixSupports()
        )
        let diffs = fixEngine.preview(plan)
        let backupRoot =
            supportDirectory
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent("<timestamp>-\(plan.id)", isDirectory: true)
            .path

        self.activeFixSheet = ActiveFixSheetState(
            request: adjustedRequest,
            plan: plan,
            diffs: diffs,
            backupDirectoryPreviewPath: backupRoot
        )
    }

    public func openSuggestedFix(_ kind: FixKind, for finding: Finding) throws {
        let candidateArtifacts = finding.artifacts.compactMap { artifactsIndex[$0] }
        guard !candidateArtifacts.isEmpty else {
            throw BentoFixesError.targetNotFound("Finding has no associated modifiable artifacts.")
        }

        let request: FixRequest
        switch kind {
        case .consolidateSkillsViaSymlink:
            let skills = candidateArtifacts.filter { $0.kind == .skill }
            request = FixRequest(
                kind: .consolidateSkillsViaSymlink,
                artifacts: skills.isEmpty ? candidateArtifacts : skills,
                confirmed: true
            )

        case .replaceDuplicateRulesWithImport:
            let rules = candidateArtifacts.filter { $0.kind == .rules }
            if rules.count >= 2 {
                let importSupporting = workspace.allFixSupports()
                let source =
                    rules.first(where: {
                        importSupporting[$0.agent]?.supportsAtImports == true
                            && !$0.name.lowercased().contains("agents.md")
                    })
                    ?? rules.first(where: { importSupporting[$0.agent]?.supportsAtImports == true })
                    ?? rules[0]
                let target = rules.first(where: { $0.id != source.id }) ?? rules[1]
                request = FixRequest(
                    kind: .replaceDuplicateRulesWithImport,
                    artifact: source,
                    targetRulesPath: target.location.path,
                    confirmed: true
                )
            } else {
                request = FixRequest(kind: kind, artifact: candidateArtifacts[0], confirmed: true)
            }

        default:
            request = FixRequest(kind: kind, artifact: candidateArtifacts[0], confirmed: true)
        }

        try openFixPreview(for: request)
    }

    public func dismissFixSheet() {
        activeFixSheet = nil
    }

    /// Applies the currently previewed `FixPlan` ONLY when `allowChanges == true`.
    ///
    /// - Important: Never invokes `fixEngine.apply` when `allowChanges` is `false`.
    public func applyActiveFixPlan() async {
        guard allowChanges else {
            lastErrorMessage = BentoFixesError.allowChangesDisabled.localizedDescription
            return
        }
        guard let sheet = activeFixSheet else { return }

        do {
            let result = try await fixEngine.apply(
                sheet.plan,
                allowChanges: true,
                postStateVerifier: nil
            )
            activeFixSheet = nil
            statusBannerMessage =
                "Applied \(sheet.plan.kind.displayName) (backup saved at \(abbreviateHomePath(result.backupDir.path)))."
            await refreshAll()
        } catch {
            lastErrorMessage = error.localizedDescription
            self.fixHistory = (try? store.fetchFixJournalEntries(limit: 200)) ?? self.fixHistory
        }
    }

    /// Undoes a previously applied fix ONLY when `allowChanges == true`.
    ///
    /// - Important: Never invokes `fixEngine.undo` when `allowChanges` is `false`.
    public func undoFix(id: String, force: Bool = false) async {
        guard allowChanges else {
            lastErrorMessage = BentoFixesError.allowChangesDisabled.localizedDescription
            return
        }

        do {
            _ = try await fixEngine.undo(
                fixID: id,
                allowChanges: true,
                force: force
            )
            pendingForceUndoEntry = nil
            statusBannerMessage = "Restored backup for fix \(id)."
            await refreshAll()
        } catch BentoFixesError.postApplyModified(let modifiedPath) where !force {
            pendingForceUndoEntry = fixHistory.first { $0.id == id }
            lastErrorMessage =
                "'\(abbreviateHomePath(modifiedPath))' was modified after this fix was applied. Confirm Force Undo to overwrite from backup."
        } catch {
            lastErrorMessage = error.localizedDescription
            self.fixHistory = (try? store.fetchFixJournalEntries(limit: 200)) ?? self.fixHistory
        }
    }

    // MARK: - Opt-in Exact Token-Count APIs & Request Preview (`PLAN.md` §6.3, §7, §11 T15)

    public func isTokenCountAPIEnabled(for provider: TokenCountAPIProviderID) -> Bool {
        switch provider {
        case .anthropic:
            return anthropicCountAPIEnabled
        case .gemini:
            return geminiCountAPIEnabled
        }
    }

    public func setTokenCountAPIEnabled(_ enabled: Bool, for provider: TokenCountAPIProviderID) throws {
        switch provider {
        case .anthropic:
            anthropicCountAPIEnabled = enabled
            try store.setSetting(enabled, forKey: Self.anthropicAPIEnabledSettingKey)
            if !enabled {
                confirmedAPICounters.removeValue(forKey: .claudeCode)
            }
        case .gemini:
            geminiCountAPIEnabled = enabled
            try store.setSetting(enabled, forKey: Self.geminiAPIEnabledSettingKey)
            if !enabled {
                confirmedAPICounters.removeValue(forKey: .gemini)
            }
        }
    }

    /// Builds a zero-network request preview containing ONLY artifact text (never logs) and redacted auth headers.
    public func prepareExactTokenCountPreview(
        for provider: TokenCountAPIProviderID,
        repoPath: String? = nil
    ) async throws -> TokenCountRequestPreview {
        guard isTokenCountAPIEnabled(for: provider) else {
            throw TokenCountAPIError.notEnabled(provider)
        }
        let targetRepo = repoPath ?? selectedRepoPath ?? repositories.first?.path
        guard let targetRepo else {
            throw BentoFixesError.targetNotFound(
                "Select or discover a repository before previewing token-count requests.")
        }

        let counter = makeAPICounter(for: provider, isEnabled: true)
        var probesByHash: [String: MCPProbeRecord] = [:]
        for record in (try? store.allMCPProbes()) ?? [] where record.ok {
            probesByHash[record.serverConfigHash] = record
        }

        let agent = provider.targetAgent
        let targets = try await workspace.tokenizableBudgetTargets(
            for: agent,
            folder: URL(fileURLWithPath: targetRepo).standardizedFileURL,
            mcpProbesByConfigHash: probesByHash
        )

        var previewItems: [TokenCountPreviewItem] = []
        for (idx, target) in targets.enumerated() {
            let request = try counter.buildRequest(text: target.text, model: target.effectiveModel)
            let endpoint = request.url?.absoluteString ?? ""
            let method = request.httpMethod ?? "POST"
            let redacted = TokenCountPreviewItem.redactHeaders(request.allHTTPHeaderFields ?? [:])
            let bodyString = String(decoding: request.httpBody ?? Data(), as: UTF8.self)

            previewItems.append(
                TokenCountPreviewItem(
                    id: "\(provider.rawValue):\(idx):\(target.cacheKey)",
                    artifactID: target.artifactID,
                    artifactName: target.artifactName,
                    kind: target.kind,
                    category: target.category,
                    label: target.label,
                    endpointURL: endpoint,
                    httpMethod: method,
                    redactedHeaders: redacted,
                    httpBodyPreview: bodyString,
                    rawText: target.text,
                    contentHash: target.cacheKey,
                    model: target.effectiveModel
                )
            )
        }

        let preview = TokenCountRequestPreview(
            provider: provider,
            agent: agent,
            repoPath: targetRepo,
            items: previewItems
        )
        self.activeTokenCountPreview = preview
        return preview
    }

    /// Executes the user-confirmed token-count API requests, caches exact counts by content hash, and updates budgets to `.exact`.
    public func confirmAndRunExactTokenCount(preview: TokenCountRequestPreview) async throws {
        guard isTokenCountAPIEnabled(for: preview.provider) else {
            throw TokenCountAPIError.notEnabled(preview.provider)
        }

        let counter = confirmedAPICounters[preview.agent] ?? makeAPICounter(for: preview.provider, isEnabled: true)
        for item in preview.items {
            _ = try await counter.countTokens(
                text: item.rawText,
                contentHash: item.contentHash,
                model: item.model
            )
        }
        confirmedAPICounters[preview.agent] = counter
        activeTokenCountPreview = nil

        if let currentSnapshot = snapshot {
            try await rebuildDerivedState(from: currentSnapshot, runLogIngest: false)
        }
    }

    // MARK: - Keychain API Keys (`PLAN.md` §7)

    public func saveAPIKey(_ rawKey: String?, for provider: TokenCountAPIProviderID) throws {
        try apiKeyStore.setAPIKey(rawKey, for: provider)
        apiKeyPresenceVersion += 1
        let trimmed = rawKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            confirmedAPICounters.removeValue(forKey: provider.targetAgent)
        }
    }

    public func hasStoredAPIKey(for provider: TokenCountAPIProviderID) -> Bool {
        _ = apiKeyPresenceVersion
        guard let key = try? apiKeyStore.apiKey(for: provider) else {
            return false
        }
        return !key.isEmpty
    }

    // MARK: - Explicit-Consent MCP Probing (`PLAN.md` §6.4, §7)

    public func grantMCPConsentAndProbe(_ entry: MCPServerInventoryEntry) async {
        do {
            try mcpConsentStore.grantConsent(forHash: entry.configHash)
            let prober = MCPProber(
                consentStore: mcpConsentStore,
                cache: store,
                urlSession: urlSessionOverride,
                now: environment.now
            )
            let workingURL: URL
            if let repoPath = entry.repoPath {
                workingURL = URL(fileURLWithPath: repoPath).standardizedFileURL
            } else if let selectedRepoPath {
                workingURL = URL(fileURLWithPath: selectedRepoPath).standardizedFileURL
            } else {
                workingURL = environment.home
            }
            let declaredEnv = MCPEnvironmentResolver.resolveDeclaredEnvValues(
                for: entry.artifact,
                config: entry.config,
                in: environment
            )
            let tokenizer = try makeConfiguredTokenizer()
            _ = try await prober.probe(
                serverName: entry.serverName,
                agent: entry.agent,
                config: entry.config,
                workingDirectory: workingURL,
                homeDirectory: environment.home,
                basePATH: environment.env["PATH"] ?? ProcessInfo.processInfo.environment["PATH"],
                declaredEnvValues: declaredEnv,
                tokenizer: tokenizer,
                forceRefresh: true
            )
            if let currentSnapshot = snapshot {
                try await rebuildDerivedState(from: currentSnapshot, runLogIngest: false)
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    public func revokeMCPConsent(forHash hash: String) {
        try? mcpConsentStore.revokeConsent(forHash: hash)
        if let snapshot {
            let probes = (try? store.allMCPProbes()) ?? []
            self.mcpServerEntries = buildMCPServerInventory(from: snapshot, probes: probes)
        }
    }

    public func revokeAllMCPConsents() {
        try? mcpConsentStore.revokeAll()
        if let snapshot {
            let probes = (try? store.allMCPProbes()) ?? []
            self.mcpServerEntries = buildMCPServerInventory(from: snapshot, probes: probes)
        }
    }

    // MARK: - Settings Persistence & Data Deletion (`PLAN.md` §6.7, §7)

    public func saveSettingsAndRefresh() async {
        let parsedRoots = Self.parseRootsList(from: shallowScanRootsText)
        try? store.setSetting(parsedRoots, forKey: Self.shallowScanRootsSettingKey)
        try? store.setSetting(includeShallowScan, forKey: Self.includeShallowScanSettingKey)
        try? store.setSetting(max(1, retentionDays), forKey: Self.retentionDaysSettingKey)
        try? store.setSetting(max(1, unusedWindowDays), forKey: Self.unusedWindowDaysSettingKey)
        try? store.setSetting(max(1, unusedMinimumSessions), forKey: Self.unusedMinSessionsSettingKey)
        try? store.setCanonicalSkillsDirectory(canonicalSkillsDirectory)
        #if DEBUG
            let trimmedDebugName = debugProductNameOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedDebugName.isEmpty {
                try? store.removeSetting(forKey: Self.debugProductNameSettingKey)
            } else {
                try? store.setSetting(trimmedDebugName, forKey: Self.debugProductNameSettingKey)
            }
        #endif
        await refreshAll()
    }

    @discardableResult
    public func pruneOldUsageEventsNow() throws -> Int {
        let cutoff = environment.now().addingTimeInterval(-Double(max(1, retentionDays)) * 86_400.0)
        let count = try store.pruneUsageEvents(olderThan: cutoff)
        statusBannerMessage = "Pruned \(count) expired usage event(s) older than \(retentionDays) days."
        return count
    }

    /// Wipes every persisted SQLite table (snapshots, usage events, sessions, findings, MCP probes, fix journal, settings)
    /// and optionally deletes Keychain API keys (`PLAN.md` §7 `"Delete all <Product.name> data"`).
    public func deleteAllProductData(includeAPIKeys: Bool = false) async throws {
        coalescedLogDeltaTask?.cancel()
        coalescedLogDeltaTask = nil
        derivedRebuildGeneration &+= 1
        try store.deleteAllData()
        try mcpConsentStore.revokeAll()
        confirmedAPICounters.removeAll()
        if includeAPIKeys {
            try apiKeyStore.setAPIKey(nil, for: .anthropic)
            try apiKeyStore.setAPIKey(nil, for: .gemini)
            apiKeyPresenceVersion += 1
        }
        loadPersistedSettings()
        clearExcerptCaches()
        expandedFindingSpanIDs.removeAll()
        lastHandledSnapshotID = nil
        lastRawHygieneFindings = nil
        snapshot = nil
        repositories = []
        totalArtifactCount = 0
        artifactsIndex = [:]
        artifactsByAgent = [:]
        persistedFindings = []
        allFindings = []
        errorFindingCount = 0
        warningFindingCount = 0
        repoBudgetsByPath = [:]
        biggestBudgetConsumers = []
        repoUsageByPath = [:]
        globalUsageItems = []
        unusedGlobalUsageCount = 0
        globalUsageSummary = nil
        fixHistory = []
        mcpServerEntries = []
        tccNotices = []
        statusBannerMessage = "Deleted all local \(effectiveProductName) data."
    }

    // MARK: - Sparkle Application Updates (`PLAN.md` §0 Rule 5, §7, §11 T16)

    public var isUpdaterAvailable: Bool {
        updater.isUpdaterAvailable
    }

    public var canCheckForUpdates: Bool {
        updater.canCheckForUpdates
    }

    public var updaterFeedURLString: String? {
        updater.feedURLString
    }

    /// Enables or turns off automatic Sparkle background update checks and persists the preference.
    public func setAutomaticallyChecksForUpdates(_ enabled: Bool) throws {
        automaticallyChecksForUpdates = enabled
        try store.setSetting(enabled, forKey: Self.automaticUpdatesSettingKey)
        updater.setAutomaticallyChecksForUpdates(enabled)
    }

    /// Triggers an explicit user-requested Sparkle update check.
    public func checkForUpdates() {
        updater.checkForUpdates()
    }

    // MARK: - Consented Companion CLI Symlink Installer (`PLAN.md` §11 T16)

    /// Returns the embedded `<App.app>/Contents/Helpers/<Product.cliName>` URL if bundled and executable.
    public var embeddedCLIBinaryURL: URL? {
        cliInstaller.embeddedCLIBinaryURL()
    }

    /// Resolves the target symlink URL for the active `selectedCLIInstallPreset`.
    public func currentCLISymlinkURL() -> URL {
        selectedCLIInstallPreset.symlinkURL(homeDirectory: environment.home)
    }

    /// Read-only inspection of the active CLI symlink destination.
    public func currentCLIInstallStatus() -> CLIInstallStatus {
        _ = cliStatusRevision
        return cliInstaller.status(at: currentCLISymlinkURL())
    }

    /// Opens the explicit user-consent confirmation dialog before creating or updating a CLI symlink.
    public func requestInstallCLI(preset: CLIInstallDestinationPreset? = nil) {
        if let preset {
            selectedCLIInstallPreset = preset
        }
        isShowingInstallCLIConfirmation = true
    }

    /// Executes the user-consented CLI symlink creation via `BentoFixes.CLIInstaller`.
    @discardableResult
    public func confirmInstallCLI() throws -> CLIInstallResult {
        let destination = currentCLISymlinkURL()
        do {
            let result = try cliInstaller.install(
                to: destination,
                userConsented: true,
                pathEnvironment: environment.env["PATH"] ?? ProcessInfo.processInfo.environment["PATH"]
            )
            isShowingInstallCLIConfirmation = false
            cliStatusRevision += 1
            let displayDest = abbreviateHomePath(result.symlinkURL.path)
            if result.isDirectoryOnPATH {
                statusBannerMessage = "Installed \(Product.cliName) symlink at \(displayDest)."
            } else {
                let binDir = abbreviateHomePath(result.symlinkURL.deletingLastPathComponent().path)
                statusBannerMessage =
                    "Installed \(Product.cliName) symlink at \(displayDest). Add \(binDir) to your shell PATH to run \(Product.cliName) anywhere."
            }
            return result
        } catch {
            isShowingInstallCLIConfirmation = false
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    /// Removes the installed CLI symlink after explicit user consent.
    public func uninstallCLISymlink(userConsented: Bool) throws {
        let destination = currentCLISymlinkURL()
        do {
            try cliInstaller.uninstall(at: destination, userConsented: userConsented)
            cliStatusRevision += 1
            statusBannerMessage = "Removed \(Product.cliName) symlink from \(abbreviateHomePath(destination.path))."
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    public func abbreviateHomePath(_ path: String) -> String {
        let homePath = environment.home.standardizedFileURL.path
        if path == homePath {
            return "~"
        }
        if path.hasPrefix(homePath + "/") {
            return "~/" + path.dropFirst(homePath.count + 1)
        }
        return path
    }

    // MARK: - Private Helpers

    private func loadPersistedSettings() {
        self.allowChanges = (try? store.allowChangesEnabled()) ?? false
        if let savedRoots = try? store.setting([String].self, forKey: Self.shallowScanRootsSettingKey),
            !savedRoots.isEmpty
        {
            self.shallowScanRootsText = savedRoots.joined(separator: ", ")
        } else {
            self.shallowScanRootsText = RepoDiscoveryOptions.defaultShallowScanRelativeRoots.joined(
                separator: ", "
            )
        }
        self.includeShallowScan = (try? store.setting(Bool.self, forKey: Self.includeShallowScanSettingKey)) ?? true
        self.manualRepoPaths = (try? store.setting([String].self, forKey: Self.manualRepoPathsSettingKey)) ?? []
        self.retentionDays =
            (try? store.setting(Int.self, forKey: Self.retentionDaysSettingKey)) ?? BentoStore.defaultRetentionDays
        self.unusedWindowDays =
            (try? store.setting(Int.self, forKey: Self.unusedWindowDaysSettingKey))
            ?? UsageJoinEngine.defaultWindowDays
        self.unusedMinimumSessions =
            (try? store.setting(Int.self, forKey: Self.unusedMinSessionsSettingKey))
            ?? UsageJoinEngine.defaultMinimumSessions
        self.canonicalSkillsDirectory = (try? store.canonicalSkillsDirectory()) ?? ""
        self.anthropicCountAPIEnabled =
            (try? store.setting(Bool.self, forKey: Self.anthropicAPIEnabledSettingKey)) ?? false
        self.geminiCountAPIEnabled =
            (try? store.setting(Bool.self, forKey: Self.geminiAPIEnabledSettingKey)) ?? false
        let autoUpdates = (try? store.setting(Bool.self, forKey: Self.automaticUpdatesSettingKey)) ?? false
        self.automaticallyChecksForUpdates = autoUpdates
        self.updater.setAutomaticallyChecksForUpdates(autoUpdates)
        #if DEBUG
            self.debugProductNameOverride =
                (try? store.setting(String.self, forKey: Self.debugProductNameSettingKey)) ?? ""
        #endif
    }

    private static func loadRepoDiscoveryOptions(from store: BentoStore) -> RepoDiscoveryOptions {
        let roots =
            (try? store.setting([String].self, forKey: shallowScanRootsSettingKey))
            ?? RepoDiscoveryOptions.defaultShallowScanRelativeRoots
        let includeShallow = (try? store.setting(Bool.self, forKey: includeShallowScanSettingKey)) ?? true
        let manualPaths = ((try? store.setting([String].self, forKey: manualRepoPathsSettingKey)) ?? []).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let pinned = (try? store.pinnedRepoPaths()) ?? []
        return RepoDiscoveryOptions(
            manualPaths: manualPaths,
            pinnedPaths: pinned,
            includeShallowScan: includeShallow,
            shallowScanRelativeRoots: roots.isEmpty ? RepoDiscoveryOptions.defaultShallowScanRelativeRoots : roots
        )
    }

    private func buildCurrentRepoDiscoveryOptions() -> RepoDiscoveryOptions {
        let roots = Self.parseRootsList(from: shallowScanRootsText)
        let manualURLs = manualRepoPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let pinned = (try? store.pinnedRepoPaths()) ?? []
        return RepoDiscoveryOptions(
            manualPaths: manualURLs,
            pinnedPaths: pinned,
            includeShallowScan: includeShallowScan,
            shallowScanRelativeRoots: roots.isEmpty ? RepoDiscoveryOptions.defaultShallowScanRelativeRoots : roots
        )
    }

    private static func parseRootsList(from raw: String) -> [String] {
        raw
            .split { $0 == "," || $0.isNewline }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func makeAPICounter(for provider: TokenCountAPIProviderID, isEnabled: Bool) -> any ExactAPITokenCounting {
        switch provider {
        case .anthropic:
            return AnthropicCountTokens(
                isEnabled: isEnabled,
                keyProvider: apiKeyStore,
                session: urlSessionOverride
            )
        case .gemini:
            return GeminiCountTokens(
                isEnabled: isEnabled,
                keyProvider: apiKeyStore,
                session: urlSessionOverride
            )
        }
    }

    private func makeConfiguredTokenizer(base: AgentTokenizerRegistry? = nil) throws -> AgentTokenizerRegistry {
        var tokenizer = try base ?? AgentTokenizerRegistry()
        let calibrations = (try? store.calibrations(for: nil)) ?? []
        if !calibrations.isEmpty {
            tokenizer.applyCalibrations(calibrations)
        }
        if anthropicCountAPIEnabled, let counter = confirmedAPICounters[.claudeCode] {
            tokenizer.setExactAPICounter(counter, for: .claudeCode)
        }
        if geminiCountAPIEnabled, let counter = confirmedAPICounters[.gemini] {
            tokenizer.setExactAPICounter(counter, for: .gemini)
        }
        return tokenizer
    }

    private func buildMCPServerInventory(
        from activeSnapshot: Snapshot,
        probes: [MCPProbeRecord]
    ) -> [MCPServerInventoryEntry] {
        Self.buildMCPServerInventoryList(
            from: activeSnapshot,
            probes: probes,
            consentedHashes: mcpConsentStore.allConsentedHashes
        )
    }

    nonisolated private static func buildMCPServerInventoryList(
        from activeSnapshot: Snapshot,
        probes: [MCPProbeRecord],
        consentedHashes: Set<String>
    ) -> [MCPServerInventoryEntry] {
        let probesByHash = Dictionary(probes.map { ($0.serverConfigHash, $0) }, uniquingKeysWith: { first, _ in first })

        var entries: [MCPServerInventoryEntry] = []
        var seenIDs: Set<String> = []

        for (scope, list) in activeSnapshot.scopedArtifacts {
            for artifact in list {
                guard case .mcpServer(let config) = artifact.payload else { continue }
                let hash = MCPServerConfigHasher.hash(config)
                let key = "\(artifact.agent.rawValue):\(hash):\(artifact.id.rawValue)"
                guard seenIDs.insert(key).inserted else { continue }
                entries.append(
                    MCPServerInventoryEntry(
                        configHash: hash,
                        serverName: artifact.name,
                        agent: artifact.agent,
                        artifact: artifact,
                        config: config,
                        repoPath: scope.repoPath,
                        hasConsent: consentedHashes.contains(hash),
                        cachedProbe: probesByHash[hash]
                    )
                )
            }
        }

        return entries.sorted { lhs, rhs in
            if lhs.agent != rhs.agent {
                return lhs.agent < rhs.agent
            }
            return lhs.serverName.localizedCaseInsensitiveCompare(rhs.serverName) == .orderedAscending
        }
    }

    private func startLiveWatchSubscription() {
        let ws = workspace
        deltaSubscriptionTask = Task { [weak self] in
            await ws.startWatching()
            let stream = await ws.deltas()
            for await delta in stream {
                guard !Task.isCancelled, let self else { break }
                await self.handleLiveWatchDelta(delta)
            }
        }
    }

    private func handleLiveWatchDelta(_ delta: SnapshotDelta) async {
        // Deduplicate `.fullScan` deltas emitted by an explicit `refreshAll()` call.
        if delta.snapshot.id == lastHandledSnapshotID {
            return
        }
        if explicitRefreshDepth > 0 && delta.reason == .fullScan {
            lastHandledSnapshotID = delta.snapshot.id
            return
        }

        // Pure session-log churn (e.g. an active AI coding agent streaming JSONL turns)
        // never alters rule/config artifacts when `rescannedScopes` is empty: coalesce bursts
        // and reuse the cached hygiene findings rather than re-auditing all repos continuously.
        if delta.rescannedScopes.isEmpty && !delta.changedLogAgents.isEmpty {
            let latestSnapshot = delta.snapshot
            coalescedLogDeltaTask?.cancel()
            coalescedLogDeltaTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                guard self.explicitRefreshDepth == 0 else { return }
                let reusedHygiene = self.lastRawHygieneFindings
                try? await self.rebuildDerivedState(
                    from: latestSnapshot,
                    runLogIngest: true,
                    reusedHygieneFindings: reusedHygiene
                )
            }
            return
        }

        coalescedLogDeltaTask?.cancel()
        coalescedLogDeltaTask = nil
        let runLogs = !delta.changedLogAgents.isEmpty
        try? await rebuildDerivedState(
            from: delta.snapshot,
            runLogIngest: runLogs,
            reusedHygieneFindings: nil
        )
    }

    private static func sortUsageItems(
        _ items: [ArtifactUsageJoin],
        by order: UsageSortOrder
    ) -> [ArtifactUsageJoin] {
        items.sorted { lhs, rhs in
            switch order {
            case .costTimesUnused:
                if lhs.costTimesUnusedScore != rhs.costTimesUnusedScore {
                    return lhs.costTimesUnusedScore > rhs.costTimesUnusedScore
                }
                if lhs.tokensCostPerSession != rhs.tokensCostPerSession {
                    return lhs.tokensCostPerSession > rhs.tokensCostPerSession
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending

            case .tokensPerSession:
                if lhs.tokensCostPerSession != rhs.tokensCostPerSession {
                    return lhs.tokensCostPerSession > rhs.tokensCostPerSession
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending

            case .invocations:
                if lhs.invocationCount != rhs.invocationCount {
                    return lhs.invocationCount > rhs.invocationCount
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending

            case .name:
                let cmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if cmp != .orderedSame {
                    return cmp == .orderedAscending
                }
                return lhs.agent < rhs.agent
            }
        }
    }

    nonisolated private static func fitCalibrations(
        sessions: [SessionRecord],
        workspace: Workspace,
        uncalibratedTokenizer: AgentTokenizerRegistry,
        probesByHash: [String: MCPProbeRecord],
        fallbackEstimate: MCPFallbackEstimate?,
        fileSystem: any ReadOnlyFileSystem,
        now: Date
    ) async -> [CalibrationRecord] {
        struct CacheKey: Hashable {
            var agent: AgentID
            var folderPath: String
            var modelKey: String
        }

        let budgetCapable = Set(workspace.budgetCapableAgents())
        var cachedBudgets: [CacheKey: Budget] = [:]
        var samples: [CalibrationSample] = []

        for session in sessions where budgetCapable.contains(session.agent) {
            guard let rawCwd = session.cwd,
                let firstTurn = session.firstTurnInput,
                firstTurn > 0
            else {
                continue
            }
            let folderURL = URL(fileURLWithPath: rawCwd).standardizedFileURL
            guard fileSystem.exists(folderURL) else { continue }

            let key = CacheKey(
                agent: session.agent,
                folderPath: folderURL.path,
                modelKey: session.model ?? ""
            )
            let predicted: Budget
            if let hit = cachedBudgets[key] {
                predicted = hit
            } else {
                guard
                    let computed = try? await workspace.budget(
                        for: session.agent,
                        folder: folderURL,
                        model: session.model,
                        tokenizer: uncalibratedTokenizer,
                        mcpProbesByConfigHash: probesByHash,
                        mcpFallbackEstimate: fallbackEstimate
                    )
                else {
                    continue
                }
                cachedBudgets[key] = computed
                predicted = computed
            }

            let effectiveModel = predicted.model ?? session.model ?? "*"
            let baseID = uncalibratedTokenizer.baseCounterID(for: session.agent, model: effectiveModel)
            let userMsgTokens = CalibrationFitter.estimateUserMessageTokens(
                charCount: session.firstUserMessageCharCount
            )
            samples.append(
                CalibrationSample(
                    agent: session.agent,
                    sessionID: session.sessionID,
                    model: effectiveModel,
                    tokenizerID: baseID,
                    predictedPrePromptTokens: predicted.prePromptTokens,
                    measuredFirstTurnInput: firstTurn,
                    userMessageEstimatedTokens: userMsgTokens
                )
            )
        }

        guard !samples.isEmpty else { return [] }
        return CalibrationFitter().fit(samples: samples, now: now)
    }
}
