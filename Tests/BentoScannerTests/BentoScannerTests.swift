import BentoAdapters
import BentoCore
import BentoScanner
import BentoStore
import BentoTestSupport
import CryptoKit
import Foundation
import Testing

struct BentoScannerTests {
    @Test("Cold scan of polyglot finishes under 500 ms and discovers all 6 agents and demo-app")
    func coldScanPolyglotUnder500Milliseconds() async throws {
        let fixture = try FixtureHome(scenario: "polyglot")
        let env = fixture.makeEnvironment()
        let workspace = Workspace(environment: env)

        let clock = ContinuousClock()
        var capturedSnapshot: Snapshot?
        let elapsed = try await clock.measure {
            capturedSnapshot = try await workspace.scanFull()
        }

        let snapshot = try #require(capturedSnapshot)
        let elapsedMs =
            Double(elapsed.components.seconds) * 1_000.0
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
        #expect(elapsedMs < 500.0, "Expected cold scan < 500 ms, took \(elapsedMs) ms")

        #expect(snapshot.repos.count == 1)
        let demoRepo = try #require(snapshot.repos.first)
        #expect(demoRepo.displayName == "demo-app")

        for agent in AgentID.allCases {
            #expect(snapshot.detections[agent]?.isDetected == true)
            let resolved = snapshot.resolution(for: agent, repoPath: demoRepo.path)
            #expect(resolved != nil, "Expected resolution for \(agent.rawValue) in demo-app")
        }
        #expect(!snapshot.artifacts.isEmpty)
    }

    @Test("PathCatalogMatcher maps user, managed, project, nested subdir, skill dir, and log paths")
    func pathCatalogMatcherMapsExactScopes() throws {
        let fixture = try FixtureHome(scenario: "polyglot")
        let env = fixture.makeEnvironment()
        let repoURL = fixture.url.appendingPathComponent("repos/demo-app").standardizedFileURL
        let repo = DiscoveredRepo(
            path: repoURL.path,
            realPath: repoURL.resolvingSymlinksInPath().path,
            displayName: "demo-app",
            sources: [.claudeLogs]
        )

        let cursorRule = repoURL.appendingPathComponent(".cursor/rules/style.mdc").path
        let cursorMatch = PathCatalogMatcher.match(
            changedPaths: [cursorRule],
            adapters: AgentAdapters.all,
            repos: [repo],
            in: env
        )
        let expectedCursorScope = Set([ScanScope(agent: .cursor, repoPath: repo.path)])
        #expect(cursorMatch.scopes == expectedCursorScope)
        #expect(cursorMatch.logAgents.isEmpty)

        let nestedClaude = repoURL.appendingPathComponent("packages/ui/CLAUDE.md").path
        let nestedMatch = PathCatalogMatcher.match(
            changedPaths: [nestedClaude],
            adapters: AgentAdapters.all,
            repos: [repo],
            in: env
        )
        let expectedNestedScope = Set([ScanScope(agent: .claudeCode, repoPath: repo.path)])
        #expect(nestedMatch.scopes == expectedNestedScope)

        let claudeLog = fixture.url
            .appendingPathComponent(".claude/projects/-repos-demo-app/session-001.jsonl").path
        let logMatch = PathCatalogMatcher.match(
            changedPaths: [claudeLog],
            adapters: AgentAdapters.all,
            repos: [repo],
            in: env
        )
        #expect(logMatch.scopes.isEmpty)
        #expect(logMatch.logAgents == [.claudeCode])
    }

    @Test("Modifying a fixture file in a temp copy triggers a rescan of ONLY that adapter scope")
    func incrementalRescanUpdatesOnlyAffectedAdapterScope() async throws {
        let fixture = try FixtureHome(scenario: "polyglot")
        let tempHome = try fixture.copyToTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let env = AgentEnvironment(
            home: tempHome,
            env: ["BENTO_SYSTEM_ROOT": tempHome.path],
            fileSystem: LocalReadOnlyFileSystem(),
            now: { Date() }
        )

        let counters = AdapterCallCounters()
        let instrumentedAdapters: [any AgentAdapter] = [
            CountingAgentAdapter(base: ClaudeCodeAdapter(), counters: counters),
            CountingAgentAdapter(base: CodexAdapter(), counters: counters),
            CountingAgentAdapter(base: GeminiAdapter(), counters: counters),
            CountingAgentAdapter(base: CopilotAdapter(), counters: counters),
            CountingAgentAdapter(base: CursorAdapter(), counters: counters),
            CountingAgentAdapter(base: WindsurfAdapter(), counters: counters)
        ]

        let watcher = ManualFileWatcher()
        let store = try BentoStore.inMemory()
        let workspace = Workspace(
            environment: env,
            adapters: instrumentedAdapters,
            store: store,
            watcher: watcher
        )

        let initial = try await workspace.scanFull()
        let demoRepo = try #require(initial.repos.first)
        var deltaIterator = await workspace.deltas().makeAsyncIterator()
        await workspace.startWatching()

        // 1. Modify ONLY a Cursor project rule file inside demo-app.
        counters.reset()
        let cursorRuleURL = URL(fileURLWithPath: demoRepo.path)
            .appendingPathComponent(".cursor/rules/style.mdc")
        let originalCursorText = try String(contentsOf: cursorRuleURL, encoding: .utf8)
        let updatedCursorText = originalCursorText + "\n- Prefer value types in Swift 6.\n"
        try Data(updatedCursorText.utf8).write(to: cursorRuleURL)

        await watcher.emit(paths: [cursorRuleURL.path], streamKind: .configuration)
        let cursorDelta = try #require(await deltaIterator.next())

        let expectedCursorScope = ScanScope(agent: .cursor, repoPath: demoRepo.path)
        #expect(cursorDelta.reason == .incrementalRescan)
        #expect(cursorDelta.rescannedScopes == [expectedCursorScope])
        #expect(counters.discoverSnapshot() == [expectedCursorScope: 1])
        #expect(counters.resolveSnapshot() == [expectedCursorScope: 1])

        let updatedCursorArtifacts = cursorDelta.snapshot.artifacts(
            agent: .cursor,
            repoPath: demoRepo.path
        )
        let hasUpdatedRule = updatedCursorArtifacts.contains { artifact in
            if case .rules(let doc) = artifact.payload {
                return doc.content.contains("Prefer value types in Swift 6.")
            }
            return false
        }
        #expect(hasUpdatedRule)

        // 2. Modify ONLY a user-level Claude Code memory file (~/.claude/CLAUDE.md).
        counters.reset()
        let userClaudeURL = tempHome.appendingPathComponent(".claude/CLAUDE.md")
        let originalClaudeText = try String(contentsOf: userClaudeURL, encoding: .utf8)
        let updatedClaudeText = originalClaudeText + "\n- Verify incremental scanner isolation.\n"
        try Data(updatedClaudeText.utf8).write(to: userClaudeURL)

        await watcher.emit(paths: [userClaudeURL.path], streamKind: .configuration)
        let claudeDelta = try #require(await deltaIterator.next())

        let expectedClaudeScopes: [ScanScope] = [
            ScanScope(agent: .claudeCode, repoPath: nil),
            ScanScope(agent: .claudeCode, repoPath: demoRepo.path)
        ]
        #expect(claudeDelta.rescannedScopes == expectedClaudeScopes)
        let expectedClaudeDiscoverCounts: [ScanScope: Int] = [
            ScanScope(agent: .claudeCode, repoPath: nil): 1,
            ScanScope(agent: .claudeCode, repoPath: demoRepo.path): 1
        ]
        let expectedClaudeResolveCounts: [ScanScope: Int] = [
            ScanScope(agent: .claudeCode, repoPath: demoRepo.path): 1
        ]
        #expect(counters.discoverSnapshot() == expectedClaudeDiscoverCounts)
        #expect(counters.resolveSnapshot() == expectedClaudeResolveCounts)

        await workspace.stopWatching()
    }

    @Test("FSEventsFileWatcher delivers live macOS FSEvents and supports polling fallback")
    func fsEventsAndPollingFallbackDeliverEvents() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-fsevents-\(UUID().uuidString)", isDirectory: true)
        let configDir = tempRoot.appendingPathComponent("config", isDirectory: true)
        let logsDir = tempRoot.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // 1. Live macOS FSEvents stream test.
        let fsWatcher = FSEventsFileWatcher(
            latency: 0.05,
            debounceInterval: .milliseconds(40)
        )
        let targets = FileWatchTargets(
            configurationPaths: [configDir.path],
            logPaths: [logsDir.path]
        )
        let stream = await fsWatcher.start(watching: targets)
        let usingFallback = await fsWatcher.isUsingPollingFallback
        #expect(!usingFallback)

        let targetFile = configDir.appendingPathComponent("settings.json")
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            try? Data("{\"ok\":true}\n".utf8).write(to: targetFile)
        }

        let receivedConfigEvent = await firstMatchingEvent(in: stream, timeout: .seconds(4)) { event in
            event.streamKind == .configuration
                && event.paths.contains { $0.hasSuffix("/settings.json") }
        }
        #expect(receivedConfigEvent != nil)
        await fsWatcher.stop()

        // 2. Polling fallback test when FSEvents stream is unavailable.
        let pollingWatcher = FSEventsFileWatcher(
            latency: 0.05,
            debounceInterval: .milliseconds(20),
            pollInterval: .milliseconds(60),
            forcePollingFallback: true
        )
        let pollStream = await pollingWatcher.start(watching: targets)
        #expect(await pollingWatcher.isUsingPollingFallback)

        let logFile = logsDir.appendingPathComponent("session.jsonl")
        Task {
            try? await Task.sleep(for: .milliseconds(90))
            try? Data("{\"turn\":1}\n".utf8).write(to: logFile)
        }

        let receivedPollEvent = await firstMatchingEvent(in: pollStream, timeout: .seconds(4)) { event in
            event.streamKind == .logs
                && event.paths.contains { $0.hasSuffix("/session.jsonl") }
        }
        #expect(receivedPollEvent != nil)
        await pollingWatcher.stop()
    }

    @Test("Read-only proof: full Workspace scan on chmod a-w polyglot copy leaves tree hashes identical")
    func readOnlyProofOnPolyglotCopy() async throws {
        let fixture = try FixtureHome(scenario: "polyglot")
        let tempCopy = try fixture.copyToTemporaryDirectory()
        defer {
            Self.setWritePermissionsRecursively(at: tempCopy, writable: true)
            try? FileManager.default.removeItem(at: tempCopy)
        }

        Self.setWritePermissionsRecursively(at: tempCopy, writable: false)
        let beforeManifest = try Self.computeTreeManifest(at: tempCopy)
        #expect(!beforeManifest.isEmpty)

        let env = AgentEnvironment(
            home: tempCopy,
            env: ["BENTO_SYSTEM_ROOT": tempCopy.path],
            fileSystem: LocalReadOnlyFileSystem(),
            now: { FixtureHome.defaultTimestamp }
        )
        let store = try BentoStore.inMemory()
        let workspace = Workspace(environment: env, store: store)
        let snapshot = try await workspace.scanFull()
        #expect(!snapshot.artifacts.isEmpty)
        #expect(snapshot.repos.count == 1)

        let afterManifest = try Self.computeTreeManifest(at: tempCopy)
        #expect(afterManifest == beforeManifest)
    }

    // MARK: - Helpers

    private func firstMatchingEvent(
        in stream: AsyncStream<FileChangeEvent>,
        timeout: Duration,
        predicate: @escaping @Sendable (FileChangeEvent) -> Bool
    ) async -> FileChangeEvent? {
        await withTaskGroup(of: FileChangeEvent?.self) { group in
            group.addTask {
                for await event in stream where predicate(event) {
                    return event
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private struct TreeEntry: Equatable {
        var relativePath: String
        var kind: String
        var posixPermissions: Int
        var contentSHA256: String
    }

    private static func computeTreeManifest(at root: URL) throws -> [TreeEntry] {
        let fm = FileManager.default
        let standardizedRoot = root.standardizedFileURL
        guard
            let enumerator = fm.enumerator(
                at: standardizedRoot,
                includingPropertiesForKeys: nil,
                options: []
            )
        else {
            return []
        }

        var entries: [TreeEntry] = []
        while let itemURL = enumerator.nextObject() as? URL {
            let stdItem = itemURL.standardizedFileURL
            let relPath = String(stdItem.path.dropFirst(standardizedRoot.path.count + 1))
            let attrs = try fm.attributesOfItem(atPath: stdItem.path)
            let fileType = (attrs[.type] as? FileAttributeType) ?? .typeUnknown
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0

            let kind: String
            let digest: String
            switch fileType {
            case .typeDirectory:
                kind = "dir"
                digest = ""
            case .typeSymbolicLink:
                kind = "symlink"
                digest = try fm.destinationOfSymbolicLink(atPath: stdItem.path)
            default:
                kind = "file"
                let bytes = try Data(contentsOf: stdItem)
                digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            }

            entries.append(
                TreeEntry(
                    relativePath: relPath,
                    kind: kind,
                    posixPermissions: perms,
                    contentSHA256: digest
                )
            )
        }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    private static func setWritePermissionsRecursively(at root: URL, writable: Bool) {
        let fm = FileManager.default
        let standardizedRoot = root.standardizedFileURL
        var allURLs: [URL] = [standardizedRoot]
        if let enumerator = fm.enumerator(at: standardizedRoot, includingPropertiesForKeys: nil) {
            while let url = enumerator.nextObject() as? URL {
                allURLs.append(url.standardizedFileURL)
            }
        }

        // Make writable top-down; make read-only bottom-up so parent directories lock last.
        let ordered = writable ? allURLs : allURLs.reversed()
        for url in ordered {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue }
            if (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
                continue
            }
            let current = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o755
            let updated = writable ? (current | 0o200) : (current & ~0o222)
            try? fm.setAttributes([.posixPermissions: updated], ofItemAtPath: url.path)
        }
    }
}

private final class AdapterCallCounters: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var discoverCounts: [ScanScope: Int] = [:]
    nonisolated(unsafe) private var resolveCounts: [ScanScope: Int] = [:]

    func recordDiscover(_ scope: ScanScope) {
        lock.lock()
        defer { lock.unlock() }
        discoverCounts[scope, default: 0] += 1
    }

    func recordResolve(_ scope: ScanScope) {
        lock.lock()
        defer { lock.unlock() }
        resolveCounts[scope, default: 0] += 1
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        discoverCounts.removeAll()
        resolveCounts.removeAll()
    }

    func discoverSnapshot() -> [ScanScope: Int] {
        lock.lock()
        defer { lock.unlock() }
        return discoverCounts
    }

    func resolveSnapshot() -> [ScanScope: Int] {
        lock.lock()
        defer { lock.unlock() }
        return resolveCounts
    }
}

private struct CountingAgentAdapter<Base: AgentAdapter>: AgentAdapter {
    static var id: AgentID { Base.id }

    let base: Base
    let counters: AdapterCallCounters

    var displayName: String { base.displayName }
    var capabilities: AgentCapabilities { base.capabilities }
    var paths: PathCatalog { base.paths }

    func detect(in env: AgentEnvironment) async -> DetectionResult {
        await base.detect(in: env)
    }

    func discover(in env: AgentEnvironment, folder: URL?) async throws -> [Artifact] {
        let scope = ScanScope(agent: Base.id, repoPath: folder?.standardizedFileURL.path)
        counters.recordDiscover(scope)
        return try await base.discover(in: env, folder: folder)
    }

    func resolve(_ artifacts: [Artifact], folder: URL, env: AgentEnvironment) -> Resolution {
        let scope = ScanScope(agent: Base.id, repoPath: folder.standardizedFileURL.path)
        counters.recordResolve(scope)
        return base.resolve(artifacts, folder: folder, env: env)
    }

    func builtInBudget(model: String?) -> [BudgetItem] {
        base.builtInBudget(model: model)
    }

    func budgetContributions(
        for resolved: ResolvedArtifact,
        artifact: Artifact
    ) -> [BudgetContribution] {
        base.budgetContributions(for: resolved, artifact: artifact)
    }

    func logSources(in env: AgentEnvironment) throws -> [LogSource] {
        try base.logSources(in: env)
    }

    func makeLogDecoder() -> any LogDecoder {
        base.makeLogDecoder()
    }

    func fixSupport() -> FixSupport {
        base.fixSupport()
    }
}
