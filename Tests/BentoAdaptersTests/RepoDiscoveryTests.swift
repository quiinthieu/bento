import BentoAdapters
import BentoCore
import BentoTestSupport
import CryptoKit
import Foundation
import Testing

struct RepoDiscoveryTests {
    @Test("AgentAdapters registry exposes all six v1 adapters in AgentID.allCases order")
    func adapterRegistryCoversAllAgents() {
        let adapters = AgentAdapters.all
        #expect(adapters.map { type(of: $0).id } == AgentID.allCases)
        for id in AgentID.allCases {
            let single = AgentAdapters.adapter(for: id)
            #expect(type(of: single).id == id)
        }
    }

    @Test("DiscoveredRepo round-trips through Codable and normalizes sorted unique sources")
    func discoveredRepoCodableRoundTrip() throws {
        let repo = DiscoveredRepo(
            path: "/tmp/demo-app",
            realPath: "/private/tmp/demo-app",
            displayName: "demo-app",
            sources: [.codexLogs, .claudeState, .codexLogs],
            isPinned: true
        )
        #expect(repo.sources == [.claudeState, .codexLogs])

        let encoded = try JSONEncoder().encode(repo)
        let decoded = try JSONDecoder().decode(DiscoveredRepo.self, from: encoded)
        #expect(decoded == repo)
    }

    @Test(
        "Discovers repositories across claude-basic, claude-precedence, codex-basic, gemini-basic, copilot-basic, and polyglot fixtures"
    )
    func discoversReposFromAllFixtures() throws {
        // empty -> []
        let emptyHome = try FixtureHome(scenario: "empty")
        let emptyRecording = RecordingReadOnlyFileSystem()
        #expect(RepoDiscovery.discover(in: emptyHome.makeEnvironment(fileSystem: emptyRecording)).isEmpty)

        // claude-basic -> repos/webapp via decoded ~/.claude/projects/-repos-webapp
        let claudeBasic = try FixtureHome(scenario: "claude-basic")
        let claudeBasicRepos = RepoDiscovery.discover(in: claudeBasic.makeEnvironment())
        #expect(claudeBasicRepos.map(\.displayName) == ["webapp"])
        #expect(claudeBasicRepos.first?.sources == [.claudeLogs])

        // claude-precedence -> repos/payments via ~/.claude.json projects["~/repos/payments"]
        let claudePrec = try FixtureHome(scenario: "claude-precedence")
        let claudePrecRepos = RepoDiscovery.discover(in: claudePrec.makeEnvironment())
        #expect(claudePrecRepos.map(\.displayName) == ["payments"])
        #expect(claudePrecRepos.first?.sources == [.claudeState])

        // codex-basic -> repos/backend-api via both config.toml [projects] and session_meta.cwd
        let codexBasic = try FixtureHome(scenario: "codex-basic")
        let codexRepos = RepoDiscovery.discover(in: codexBasic.makeEnvironment())
        #expect(codexRepos.map(\.displayName) == ["backend-api"])
        #expect(codexRepos.first?.sources == [.codexConfig, .codexLogs])

        // gemini-basic -> repos/storefront via SHA-256 project hash in ~/.gemini/tmp/<hash>
        let geminiBasic = try FixtureHome(scenario: "gemini-basic")
        let geminiRepos = RepoDiscovery.discover(in: geminiBasic.makeEnvironment())
        #expect(geminiRepos.map(\.displayName) == ["storefront"])
        #expect(geminiRepos.first?.sources == [.geminiLogs])

        // copilot-basic -> repos/octocat-api (and ignores ~/repos/missing-ghost-repo!)
        let copilotBasic = try FixtureHome(scenario: "copilot-basic")
        let copilotRepos = RepoDiscovery.discover(in: copilotBasic.makeEnvironment())
        #expect(copilotRepos.map(\.displayName) == ["octocat-api"])
        #expect(copilotRepos.first?.sources == [.copilotConfig, .copilotLogs])

        // polyglot -> repos/demo-app referenced across Claude, Codex, Gemini, and Copilot logs
        let polyglot = try FixtureHome(scenario: "polyglot")
        let polyglotRecording = RecordingReadOnlyFileSystem()
        let polyglotRepos = RepoDiscovery.discover(in: polyglot.makeEnvironment(fileSystem: polyglotRecording))
        #expect(polyglotRepos.map(\.displayName) == ["demo-app"])
        #expect(
            polyglotRepos.first?.sources == [
                .claudeLogs,
                .codexLogs,
                .copilotLogs,
                .geminiLogs
            ]
        )

        // Strict hermetic containment check: zero accesses outside fixture root
        let rawRoot = polyglot.url.standardizedFileURL.path
        let realRoot = polyglot.url.resolvingSymlinksInPath().standardizedFileURL.path
        for accessed in polyglotRecording.accessedPaths {
            let inRaw = accessed == rawRoot || accessed.hasPrefix(rawRoot + "/")
            let inReal = accessed == realRoot || accessed.hasPrefix(realRoot + "/")
            #expect(inRaw || inReal, "RepoDiscovery accessed path '\(accessed)' outside fixture root")
        }
    }

    @Test(
        "Dedupes symlinked repo paths by realPath, ignores missing dirs, matches real SHA-256 Gemini hashes, supports shallow .git scan (depth <= 3), and honors pin/hide options"
    )
    func dedupesSymlinksIgnoresMissingAndShallowScans() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-repodiscovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        // 1. Real repo under ~/Developer/org/alpha-service (depth 2, .git directory)
        let alphaRepo = tempHome.appendingPathComponent("Developer/org/alpha-service", isDirectory: true)
        try FileManager.default.createDirectory(
            at: alphaRepo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let alphaSubdir = alphaRepo.appendingPathComponent("packages/core", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaSubdir, withIntermediateDirectories: true)

        // Symlink alias ~/shortcuts/alpha-link -> ~/Developer/org/alpha-service
        let shortcutsDir = tempHome.appendingPathComponent("shortcuts", isDirectory: true)
        try FileManager.default.createDirectory(at: shortcutsDir, withIntermediateDirectories: true)
        let alphaSymlink = shortcutsDir.appendingPathComponent("alpha-link")
        try FileManager.default.createSymbolicLink(at: alphaSymlink, withDestinationURL: alphaRepo)

        // 2. Repo at depth 3 under ~/Projects/team/mobile/ios-app (.git worktree file)
        let iosRepo = tempHome.appendingPathComponent("Projects/team/mobile/ios-app", isDirectory: true)
        try FileManager.default.createDirectory(at: iosRepo, withIntermediateDirectories: true)
        try Data("gitdir: /tmp/fake-worktree\n".utf8).write(to: iosRepo.appendingPathComponent(".git"))

        // 3. Repo at depth 4 under ~/Projects/a/b/c/too-deep (must be ignored by depth <= 3 shallow scan)
        let tooDeepRepo = tempHome.appendingPathComponent("Projects/a/b/c/too-deep", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tooDeepRepo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )

        // 4. Non-git folder under ~/code/scratch-notes (no .git -> ignored by shallow scan)
        let nonGitDir = tempHome.appendingPathComponent("code/scratch-notes", isDirectory: true)
        try FileManager.default.createDirectory(at: nonGitDir, withIntermediateDirectories: true)

        // 5. Hidden repo under ~/src/secret-prototype (.git present, but user hid it)
        let hiddenRepo = tempHome.appendingPathComponent("src/secret-prototype", isDirectory: true)
        try FileManager.default.createDirectory(
            at: hiddenRepo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )

        // Claude ~/.claude.json references the symlink alias AND a missing directory
        let claudeState = """
            {
              "projects": {
                "\(alphaSymlink.path)": {},
                "\(tempHome.appendingPathComponent("Developer/deleted-repo").path)": {}
              }
            }
            """
        try Data(claudeState.utf8).write(to: tempHome.appendingPathComponent(".claude.json"))

        // Claude encoded project dir with full encoded home prefix + hyphenated repo name
        let encodedHome = tempHome.resolvingSymlinksInPath().standardizedFileURL.path
            .replacingOccurrences(of: "/", with: "-")
        let claudeProjDir = tempHome.appendingPathComponent(
            ".claude/projects/\(encodedHome)-Developer-org-alpha-service",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: claudeProjDir, withIntermediateDirectories: true)

        // Codex session_meta.cwd points to a subdirectory inside alphaRepo -> normalizes to alphaRepo root
        let codexSessDir = tempHome.appendingPathComponent(".codex/sessions/2026/10/30", isDirectory: true)
        try FileManager.default.createDirectory(at: codexSessDir, withIntermediateDirectories: true)
        let codexLine =
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"s1\",\"cwd\":\"\(alphaSubdir.path)\"}}\n"
        try Data(codexLine.utf8).write(to: codexSessDir.appendingPathComponent("rollout-1.jsonl"))

        // Gemini real SHA-256(realPath) project hash for iosRepo + unmatched orphan hash
        let iosRealPath = iosRepo.resolvingSymlinksInPath().standardizedFileURL.path
        let iosHash = SHA256.hash(data: Data(iosRealPath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let geminiChatsDir = tempHome.appendingPathComponent(".gemini/tmp/\(iosHash)/chats", isDirectory: true)
        let orphanGeminiDir = tempHome.appendingPathComponent(
            ".gemini/tmp/ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/chats",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: geminiChatsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: orphanGeminiDir, withIntermediateDirectories: true)
        try Data("{\"sessionId\":\"g1\"}\n".utf8).write(to: geminiChatsDir.appendingPathComponent("session-1.json"))

        let env = AgentEnvironment(
            home: tempHome,
            env: ["BENTO_SYSTEM_ROOT": tempHome.path],
            fileSystem: LocalReadOnlyFileSystem(),
            now: { FixtureHome.defaultTimestamp }
        )

        let options = RepoDiscoveryOptions(
            manualPaths: [tempHome.appendingPathComponent("missing-manual-folder")],
            pinnedPaths: [alphaSymlink.path],
            hiddenPaths: [hiddenRepo.path],
            includeShallowScan: true
        )

        let discovered = RepoDiscovery.discover(in: env, options: options)
        #expect(discovered.count == 2)

        let alpha = try #require(discovered.first { $0.displayName == "alpha-service" })
        #expect(alpha.realPath == alphaRepo.resolvingSymlinksInPath().standardizedFileURL.path)
        #expect(alpha.path == alphaRepo.standardizedFileURL.path)
        #expect(alpha.isPinned)
        #expect(alpha.sources == [.claudeLogs, .claudeState, .codexLogs, .shallowScan])

        let ios = try #require(discovered.first { $0.displayName == "ios-app" })
        #expect(ios.realPath == iosRealPath)
        #expect(!ios.isPinned)
        #expect(ios.sources == [.geminiLogs, .shallowScan])
    }
}
