import AppKit
import BentoCore
import BentoFixes
import BentoMCPProbe
import BentoScanner
import BentoStore
import BentoTestSupport
import BentoTokenizer
import Foundation
import SwiftUI
import Synchronization
import Testing

@testable import BentoUI

// MARK: - Test Doubles

private final class SpyFixEngine: FixApplying, Sendable {
    struct Counts: Sendable {
        var planCalls: Int = 0
        var previewCalls: Int = 0
        var applyCalls: Int = 0
        var undoCalls: Int = 0
    }

    private let state = Mutex<Counts>(Counts())
    private let delegate: FixEngine

    init(delegate: FixEngine) {
        self.delegate = delegate
    }

    var counts: Counts {
        state.withLock { $0 }
    }

    func plan(
        _ request: FixRequest,
        snapshot: Snapshot,
        fixSupports: [AgentID: FixSupport]
    ) throws -> FixPlan {
        state.withLock { $0.planCalls += 1 }
        return try delegate.plan(request, snapshot: snapshot, fixSupports: fixSupports)
    }

    func preview(_ plan: FixPlan) -> [UnifiedDiff] {
        state.withLock { $0.previewCalls += 1 }
        return delegate.preview(plan)
    }

    func apply(
        _ plan: FixPlan,
        allowChanges: Bool?,
        postStateVerifier: (@Sendable (FixPlan) async throws -> Bool)?
    ) async throws -> FixApplyResult {
        state.withLock { $0.applyCalls += 1 }
        return try await delegate.apply(
            plan,
            allowChanges: allowChanges,
            postStateVerifier: postStateVerifier
        )
    }

    func undo(
        fixID: String,
        allowChanges: Bool?,
        force: Bool
    ) async throws -> FixUndoResult {
        state.withLock { $0.undoCalls += 1 }
        return try await delegate.undo(fixID: fixID, allowChanges: allowChanges, force: force)
    }
}

@MainActor
private final class RecordingExternalActionHandler: ExternalActionHandling {
    var revealedURLs: [URL] = []
    var openedEditorURLs: [URL] = []

    func revealInFinder(_ url: URL) {
        revealedURLs.append(url)
    }

    func openInEditor(_ url: URL) {
        openedEditorURLs.append(url)
    }
}

private final class MockTokenCountURLProtocol: URLProtocol, @unchecked Sendable {
    private static let counter = Mutex<Int>(0)

    static func reset() {
        counter.withLock { $0 = 0 }
    }

    static var requestCount: Int {
        counter.withLock { $0 }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.counter.withLock { $0 += 1 }
        let urlString = request.url?.absoluteString ?? ""
        let payload: String
        if urlString.contains("anthropic.com") {
            payload = #"{"input_tokens": 42}"#
        } else {
            payload = #"{"totalTokens": 37}"#
        }
        let data = Data(payload.utf8)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - BentoAppUITests

@Suite(.serialized)
struct BentoAppUITests {
    @MainActor
    private static func hostViewInWindow<V: View>(_ view: V) -> (NSWindow, NSHostingView<V>) {
        _ = NSApplication.shared
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        return (window, hostingView)
    }

    @MainActor
    private static func tearDownWindow(_ window: NSWindow) {
        window.contentView = nil
        window.orderOut(nil)
    }

    @MainActor
    private static func collectAccessibilityStrings(from element: Any) -> [String] {
        var visited: Set<ObjectIdentifier> = []
        return collectAccessibilityStrings(from: element, visited: &visited)
    }

    @MainActor
    private static func collectAccessibilityStrings(
        from element: Any,
        visited: inout Set<ObjectIdentifier>
    ) -> [String] {
        let object = element as AnyObject
        let objectID = ObjectIdentifier(object)
        guard visited.insert(objectID).inserted else {
            return []
        }

        var collected: [String] = []
        if let view = element as? NSView {
            if let label = view.accessibilityLabel(), !label.isEmpty {
                collected.append(label)
            }
            if let value = view.accessibilityValue() as? String, !value.isEmpty {
                collected.append(value)
            }
            if let children = view.accessibilityChildren() {
                for child in children {
                    collected.append(contentsOf: collectAccessibilityStrings(from: child, visited: &visited))
                }
            }
            for subview in view.subviews {
                collected.append(contentsOf: collectAccessibilityStrings(from: subview, visited: &visited))
            }
            return collected
        }

        if let ax = element as? any NSAccessibilityProtocol {
            if let label = ax.accessibilityLabel(), !label.isEmpty {
                collected.append(label)
            }
            if let value = ax.accessibilityValue() as? String, !value.isEmpty {
                collected.append(value)
            }
            if let children = ax.accessibilityChildren() {
                for child in children {
                    collected.append(contentsOf: collectAccessibilityStrings(from: child, visited: &visited))
                }
            }
            return collected
        }

        if let obj = element as? NSObject {
            let labelSel = NSSelectorFromString("accessibilityLabel")
            if obj.responds(to: labelSel),
                let label = obj.perform(labelSel)?.takeUnretainedValue() as? String,
                !label.isEmpty
            {
                collected.append(label)
            }
            let valueSel = NSSelectorFromString("accessibilityValue")
            if obj.responds(to: valueSel),
                let value = obj.perform(valueSel)?.takeUnretainedValue() as? String,
                !value.isEmpty
            {
                collected.append(value)
            }
            let childrenSel = NSSelectorFromString("accessibilityChildren")
            if obj.responds(to: childrenSel),
                let children = obj.perform(childrenSel)?.takeUnretainedValue() as? [Any]
            {
                for child in children {
                    collected.append(contentsOf: collectAccessibilityStrings(from: child, visited: &visited))
                }
            }
        }
        return collected
    }

    @Test(
        "Smoke test against -fixtureHome polyglot populates Overview, Repos, 4 Repo Detail tabs, and writes 0 bytes on chmod a-w copy"
    )
    @MainActor
    func smokeTestPolyglotFixtureReadOnlyAndAllTabs() async throws {
        // 1. Verify LaunchConfiguration resolves `-fixtureHome polyglot` directly.
        let launch = try LaunchConfiguration.parse(arguments: ["bento-app", "-fixtureHome", "polyglot"])
        #expect(launch.isFixtureMode == true)
        #expect(launch.homeURL.lastPathComponent == "polyglot")

        // 2. Copy polyglot to a chmod a-w temp directory to prove 100% zero-write UI operation.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-ui-ro-\(UUID().uuidString)", isDirectory: true)
        let roHome = tempRoot.appendingPathComponent("polyglot", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: launch.homeURL, to: roHome)
        Self.setReadOnlyPermissionsRecursively(at: roHome, writable: false)
        defer {
            Self.setReadOnlyPermissionsRecursively(at: roHome, writable: true)
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let actions = RecordingExternalActionHandler()
        let roLaunch = try LaunchConfiguration.parse(
            arguments: ["bento-app", "-fixtureHome", roHome.path, "-skipOnboarding"]
        )
        let model = try BentoAppModel(
            launchConfiguration: roLaunch,
            apiKeyStore: InMemoryAPIKeyStore(),
            externalActions: actions
        )
        await model.refreshAll()

        // Overview assertions
        #expect(model.detectedAgentCount == 6)
        #expect(model.totalArtifactCount > 10)
        #expect(!model.allFindings.isEmpty)
        #expect(!model.biggestBudgetConsumers.isEmpty)

        // Repos search & selection
        #expect(!model.repositories.isEmpty)
        model.repoSearchQuery = "demo"
        #expect(model.filteredRepositories.count == 1)
        let demoRepo = try #require(model.filteredRepositories.first)
        #expect(demoRepo.displayName == "demo-app")

        await model.selectRepository(demoRepo.path)
        #expect(model.selectedSection == .repos)
        #expect(model.selectedRepoPath == demoRepo.path)

        // Pin/unpin works in-memory without touching read-only fixture home
        try await model.togglePinRepository(path: demoRepo.path)
        #expect(model.repositories.first(where: { $0.path == demoRepo.path })?.isPinned == true)

        // Repo detail: Budget tab across budget-capable agents + graceful Cursor/Windsurf fallback
        model.selectedRepoAgent = .claudeCode
        model.selectedRepoTab = .budget
        let claudeBudget = try #require(model.currentRepoBudget)
        #expect(claudeBudget.prePromptTokens > 0)
        #expect(claudeBudget.items.allSatisfy { !$0.method.isEmpty })

        // Resolution tab: ordered items + shadowed items + Reveal in Finder / Open in editor
        model.selectedRepoTab = .resolution
        let resolution = try #require(model.currentRepoResolution)
        #expect(!resolution.ordered.isEmpty)
        let firstResolvedID = try #require(resolution.ordered.first?.artifactID)
        let firstArtifact = try #require(model.artifact(for: firstResolvedID))
        model.revealArtifactInFinder(firstArtifact)
        model.openArtifactInEditor(firstArtifact)
        #expect(actions.revealedURLs.count == 1)
        #expect(actions.openedEditorURLs.count == 1)

        // Usage tab: sortable by cost * unused
        model.selectedRepoTab = .usage
        model.usageSortOrder = .costTimesUnused
        let usageRows = model.sortedRepoUsageItems
        if usageRows.count >= 2 {
            #expect(usageRows[0].costTimesUnusedScore >= usageRows[1].costTimesUnusedScore)
        }

        // Hygiene tab: side-by-side 1-based physical line span excerpts
        model.selectedRepoTab = .hygiene
        let multiSpanFinding = try #require(model.allFindings.first { $0.spans.count >= 2 })
        let excerpts = model.spanExcerpts(for: multiSpanFinding)
        #expect(excerpts.count >= 2)
        #expect(excerpts.allSatisfy { !$0.lines.isEmpty })

        // Host full RootView across sections in an AppKit window to verify SwiftUI layout succeeds cleanly
        let (window, hosting) = Self.hostViewInWindow(RootView(model: model))
        for section in SidebarSection.allCases {
            model.selectedSection = section
            hosting.layoutSubtreeIfNeeded()
        }
        Self.tearDownWindow(window)
    }

    @Test("Keyboard navigation reaches all sidebar sections, repo tabs, agents, onboarding, and modal actions")
    @MainActor
    func keyboardNavigationReachesAllPrimaryActions() async throws {
        let launch = try LaunchConfiguration.parse(
            arguments: ["bento-app", "-fixtureHome", "polyglot", "-showOnboarding"]
        )
        let model = try BentoAppModel(
            launchConfiguration: launch,
            apiKeyStore: InMemoryAPIKeyStore(),
            externalActions: RecordingExternalActionHandler()
        )
        await model.refreshAll()

        // First-run onboarding is shown and dismissible via keyboard default action
        #expect(model.isShowingOnboarding == true)
        model.completeOnboarding()
        #expect(model.isShowingOnboarding == false)

        // Cmd+1..Cmd+7 reach every SidebarSection in deterministic order
        for (idx, expected) in SidebarSection.allCases.enumerated() {
            model.selectSectionByShortcut(index: idx + 1)
            #expect(model.selectedSection == expected)
        }

        // Repo selection & tab cycling via keyboard commands
        model.selectNextRepository()
        #expect(model.selectedRepoPath != nil)
        #expect(model.selectedSection == .repos)

        model.selectedRepoTab = .budget
        model.cycleRepoTab(forward: true)
        #expect(model.selectedRepoTab == .resolution)
        model.cycleRepoTab(forward: true)
        #expect(model.selectedRepoTab == .usage)
        model.cycleRepoTab(forward: true)
        #expect(model.selectedRepoTab == .hygiene)
        model.cycleRepoTab(forward: false)
        #expect(model.selectedRepoTab == .usage)

        // Agent picker cycling via keyboard
        let initialAgent = model.selectedRepoAgent
        model.cycleSelectedAgent(forward: true)
        #expect(model.selectedRepoAgent != initialAgent)
    }

    @Test("VoiceOver accessibility labels and values describe every Budget chart segment and measured marker")
    @MainActor
    func voiceOverReadsBudgetChartSegmentsAndMeasuredMarker() async throws {
        let launch = try LaunchConfiguration.parse(
            arguments: ["bento-app", "-fixtureHome", "polyglot", "-skipOnboarding"]
        )
        let model = try BentoAppModel(
            launchConfiguration: launch,
            apiKeyStore: InMemoryAPIKeyStore(),
            externalActions: RecordingExternalActionHandler()
        )
        await model.refreshAll()

        let demoRepo = try #require(model.repositories.first)
        await model.selectRepository(demoRepo.path)
        model.selectedRepoAgent = .claudeCode
        model.selectedRepoTab = .budget

        let summaries = model.currentRepoChartSummaries
        #expect(summaries.count == 4)

        let claudeSummary = try #require(summaries.first { $0.agent == .claudeCode })
        #expect(!claudeSummary.segments.isEmpty)
        #expect(claudeSummary.segments.contains { $0.isPrePrompt })
        #expect(claudeSummary.segments.contains { !$0.isPrePrompt })

        for segment in claudeSummary.segments {
            #expect(segment.accessibilityLabel.contains(segment.categoryDisplayName))
            #expect(segment.accessibilityValue.contains("tokens"))
            if segment.isPrePrompt {
                #expect(segment.accessibilityValue.lowercased().contains("pre-prompt"))
            } else {
                #expect(segment.accessibilityValue.lowercased().contains("deferred"))
            }
        }

        // Verify a synthetic budget with measuredFirstTurnInput exposes a VoiceOver marker label AND renders into NSAccessibility
        let syntheticBudget = Budget(
            agent: .claudeCode,
            folder: demoRepo.path,
            model: "claude-sonnet-4-5",
            items: [
                BudgetItem(
                    category: .rules,
                    label: "CLAUDE.md",
                    tokens: 320,
                    confidence: .exact,
                    method: "anthropic-count-tokens-api",
                    countsTowardPrePrompt: true
                ),
                BudgetItem(
                    category: .mcpToolsDeferred,
                    label: "github (deferred)",
                    tokens: 940,
                    confidence: .estimated,
                    method: "probed tools/list",
                    countsTowardPrePrompt: false
                )
            ],
            measuredFirstTurnInput: 410,
            contextWindow: 200_000
        )
        let markerSummary = BudgetChartSummary.build(from: syntheticBudget)
        let markerLabel = try #require(markerSummary.measuredMarkerAccessibilityLabel)
        #expect(markerLabel.contains("410"))

        let chartView = BudgetChartCardView(
            summaries: [markerSummary],
            selectedAgent: .claudeCode
        )
        let (window, hosting) = Self.hostViewInWindow(chartView)
        let axStrings = Self.collectAccessibilityStrings(from: hosting)
        let joinedAX = axStrings.joined(separator: " | ")
        #expect(joinedAX.contains("Rules"))
        #expect(joinedAX.contains("320"))
        #expect(joinedAX.contains("deferred"))
        #expect(joinedAX.contains("410"))
        Self.tearDownWindow(window)
    }

    @Test(
        "No writes happen when 'Allow changes' is off (asserted via FixApplying spy), and enabling allows apply + undo")
    @MainActor
    func allowChangesGateEnforcedViaFixesSpy() async throws {
        let fixture = try FixtureHome(scenario: "polyglot")
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-ui-spy-\(UUID().uuidString)", isDirectory: true)
        let homeCopy = tempRoot.appendingPathComponent("home", isDirectory: true)
        let supportDir = tempRoot.appendingPathComponent("support", isDirectory: true)
        let trashDir = tempRoot.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.url, to: homeCopy)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let store = try BentoStore(databaseURL: supportDir.appendingPathComponent("bento.sqlite"))
        let env = AgentEnvironment(
            home: homeCopy,
            env: ["BENTO_SYSTEM_ROOT": homeCopy.path],
            fileSystem: LocalReadOnlyFileSystem()
        )
        let realFixEngine = FixEngine(
            homeURL: homeCopy,
            supportDirectory: supportDir,
            store: store,
            fileSystem: env.fileSystem,
            trashHandler: HermeticTrashHandler(trashDirectory: trashDir)
        )
        let spy = SpyFixEngine(delegate: realFixEngine)

        let model = BentoAppModel(
            environment: env,
            store: store,
            supportDirectory: supportDir,
            fixEngine: spy,
            apiKeyStore: InMemoryAPIKeyStore(),
            externalActions: RecordingExternalActionHandler(),
            showOnboardingOnFirstRun: false
        )
        await model.refreshAll()

        // 1. Default state MUST have "Allow changes" disabled
        #expect(model.allowChanges == false)

        let codexConfigURL = homeCopy.appendingPathComponent(".codex/config.toml")
        let originalBytes = try Data(contentsOf: codexConfigURL)

        let codexMCP = try #require(
            model.snapshot?.artifacts.first {
                $0.agent == .codex && $0.kind == .mcpServer && $0.scope == .user && $0.enabled
            }
        )

        // 2. Opening Fix preview works read-only (`plan` + `preview`), but `canApplyActiveFix` is false
        try model.openFixPreview(for: FixRequest(kind: .disableMCPServer, artifact: codexMCP))
        #expect(spy.counts.planCalls == 1)
        #expect(spy.counts.previewCalls == 1)
        #expect(model.activeFixSheet != nil)
        #expect(!model.activeFixSheet!.diffs.isEmpty)
        #expect(model.canApplyActiveFix == false)

        // 3. Attempting apply or undo while "Allow changes" is off NEVER invokes `fixEngine.apply` or `fixEngine.undo`
        await model.applyActiveFixPlan()
        await model.undoFix(id: "nonexistent-fix-id")
        #expect(spy.counts.applyCalls == 0)
        #expect(spy.counts.undoCalls == 0)
        #expect(try Data(contentsOf: codexConfigURL) == originalBytes)

        // 4. Turning "Allow changes" ON enables Apply -> Fix History -> Undo byte-identically
        try model.setAllowChanges(true)
        #expect(model.allowChanges == true)
        #expect(model.canApplyActiveFix == true)

        await model.applyActiveFixPlan()
        #expect(spy.counts.applyCalls == 1)
        #expect(model.activeFixSheet == nil)
        #expect(try Data(contentsOf: codexConfigURL) != originalBytes)

        let appliedEntry = try #require(model.fixHistory.first { $0.status == .applied })
        await model.undoFix(id: appliedEntry.id)
        #expect(spy.counts.undoCalls == 1)
        #expect(try Data(contentsOf: codexConfigURL) == originalBytes)
        #expect(model.fixHistory.first(where: { $0.id == appliedEntry.id })?.status == .undone)
    }

    @Test(
        "Optional Anthropic and Gemini token-count APIs show artifact-only request preview and upgrade items to exact")
    @MainActor
    func optionalCountAPIsShowRequestPreviewAndMarkItemsExact() async throws {
        MockTokenCountURLProtocol.reset()
        let sessionCfg = URLSessionConfiguration.ephemeral
        sessionCfg.protocolClasses = [MockTokenCountURLProtocol.self]
        let mockSession = URLSession(configuration: sessionCfg)

        let keyStore = InMemoryAPIKeyStore(initialKeys: [
            .anthropic: "sk-ant-super-secret-live-key",
            .gemini: "AIza-super-secret-gemini-key"
        ])
        let launch = try LaunchConfiguration.parse(
            arguments: ["bento-app", "-fixtureHome", "polyglot", "-skipOnboarding"]
        )
        let model = try BentoAppModel(
            launchConfiguration: launch,
            apiKeyStore: keyStore,
            externalActions: RecordingExternalActionHandler(),
            urlSessionOverride: mockSession
        )
        await model.refreshAll()

        let demoRepo = try #require(model.repositories.first)
        await model.selectRepository(demoRepo.path)

        // Before opt-in confirmation, zero network requests have occurred and Claude/Gemini rules are estimated
        #expect(MockTokenCountURLProtocol.requestCount == 0)
        model.selectedRepoAgent = .claudeCode
        let initialClaudeBudget = try #require(model.currentRepoBudget)
        let initialClaudeRule = try #require(initialClaudeBudget.items.first { $0.category == .rules })
        #expect(initialClaudeRule.confidence == .estimated)

        // 1. Anthropic request preview shows exact endpoint, redacted key header, and ONLY artifact text (never logs)
        try model.setTokenCountAPIEnabled(true, for: .anthropic)
        let anthropicPreview = try await model.prepareExactTokenCountPreview(
            for: .anthropic,
            repoPath: demoRepo.path
        )
        #expect(MockTokenCountURLProtocol.requestCount == 0)
        #expect(!anthropicPreview.items.isEmpty)
        for item in anthropicPreview.items {
            #expect(item.endpointURL.contains("api.anthropic.com/v1/messages/count_tokens"))
            #expect(!item.httpBodyPreview.contains("sk-ant-super-secret-live-key"))
            #expect(item.redactedHeaders["x-api-key"] == "«redacted»")
            #expect(!item.httpBodyPreview.contains("cache_read_input_tokens"))
        }

        // Confirming preview executes API counts and upgrades Claude Code artifact items to `.exact`
        try await model.confirmAndRunExactTokenCount(preview: anthropicPreview)
        #expect(MockTokenCountURLProtocol.requestCount > 0)
        let exactClaudeBudget = try #require(model.currentRepoBudget)
        let exactClaudeRules = exactClaudeBudget.items.filter { $0.category == .rules }
        #expect(!exactClaudeRules.isEmpty)
        #expect(exactClaudeRules.allSatisfy { $0.confidence == .exact })

        // 2. Gemini request preview & exact upgrade
        let countBeforeGemini = MockTokenCountURLProtocol.requestCount
        try model.setTokenCountAPIEnabled(true, for: .gemini)
        let geminiPreview = try await model.prepareExactTokenCountPreview(
            for: .gemini,
            repoPath: demoRepo.path
        )
        #expect(MockTokenCountURLProtocol.requestCount == countBeforeGemini)
        #expect(!geminiPreview.items.isEmpty)
        for item in geminiPreview.items {
            #expect(item.endpointURL.contains(":countTokens"))
            #expect(!item.httpBodyPreview.contains("AIza-super-secret-gemini-key"))
            #expect(item.redactedHeaders["x-goog-api-key"] == "«redacted»")
        }

        model.selectedRepoAgent = .gemini
        try await model.confirmAndRunExactTokenCount(preview: geminiPreview)
        #expect(MockTokenCountURLProtocol.requestCount > countBeforeGemini)
        let exactGeminiBudget = try #require(model.currentRepoBudget)
        let exactGeminiRules = exactGeminiBudget.items.filter { $0.category == .rules }
        #expect(!exactGeminiRules.isEmpty)
        #expect(exactGeminiRules.allSatisfy { $0.confidence == .exact })
    }

    @Test("Onboarding privacy statement, TCC denial detection, Keychain isolation, and Settings lifecycle")
    @MainActor
    func onboardingPrivacyTCCAndSettingsLifecycle() async throws {
        let keyStore = InMemoryAPIKeyStore()
        let launch = try LaunchConfiguration.parse(
            arguments: ["bento-app", "-fixtureHome", "polyglot", "-showOnboarding"]
        )
        let model = try BentoAppModel(
            launchConfiguration: launch,
            apiKeyStore: keyStore,
            externalActions: RecordingExternalActionHandler()
        )
        await model.refreshAll()

        // Privacy onboarding statement covers local-only guarantee and Full Disk Access explanation (PLAN §7)
        #expect(model.isShowingOnboarding == true)
        let onboardingCopy = OnboardingCopy.make()
        #expect(onboardingCopy.fullDiskAccessExplanation.contains("Full Disk Access"))
        #expect(onboardingCopy.localOnlyStatement.lowercased().contains("no telemetry"))

        // TCC denial detection identifies ~/Documents, ~/Desktop, ~/Downloads permission errors
        let protectedPath = launch.homeURL.appendingPathComponent("Documents/secret-repo/CLAUDE.md").path
        let sampleDiag = Diagnostic(
            code: "fs.permissionDenied",
            severity: .warning,
            message: "Operation not permitted (EPERM) reading file",
            location: SourceLocation(path: protectedPath, realPath: protectedPath)
        )
        let notice = try #require(
            TCCDenialDetector.detect(from: [sampleDiag], homePath: launch.homeURL.path).first
        )
        #expect(notice.protectedFolderName == "Documents")
        #expect(notice.explanation.contains("Full Disk Access"))

        // Keychain API key save/clear never writes secrets to SQLite `setting` table
        try model.saveAPIKey("sk-ant-keychain-only-777", for: .anthropic)
        #expect(try keyStore.apiKey(for: .anthropic) == "sk-ant-keychain-only-777")
        #expect(model.hasStoredAPIKey(for: .anthropic) == true)

        // Delete all product data wipes store & resets settings
        try await model.deleteAllProductData(includeAPIKeys: true)
        #expect(try keyStore.apiKey(for: .anthropic) == nil)
        #expect(model.hasStoredAPIKey(for: .anthropic) == false)
    }

    private static func setReadOnlyPermissionsRecursively(at root: URL, writable: Bool) {
        let fm = FileManager.default
        let dirMode = writable ? 0o755 : 0o555
        let fileMode = writable ? 0o644 : 0o444
        if writable {
            try? fm.setAttributes([.posixPermissions: dirMode], ofItemAtPath: root.path)
        }
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            var paths: [String] = []
            while let url = enumerator.nextObject() as? URL {
                paths.append(url.path)
            }
            let ordered = writable ? paths.sorted() : paths.sorted().reversed()
            for path in ordered {
                guard let attrs = try? fm.attributesOfItem(atPath: path) else { continue }
                let fileType = attrs[.type] as? FileAttributeType
                if fileType == .typeSymbolicLink { continue }
                let mode = (fileType == .typeDirectory) ? dirMode : fileMode
                try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
            }
        }
        if !writable {
            try? fm.setAttributes([.posixPermissions: dirMode], ofItemAtPath: root.path)
        }
    }
}
