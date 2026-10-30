import BentoAdapters
import BentoCore
import BentoTestSupport
import Foundation
import Testing

struct CodexAdapterContractTests {
    @Test("CodexAdapter satisfies shared AdapterContractSuite on codex-basic and polyglot")
    func contractSuitePassesFixtures() async throws {
        let adapter = CodexAdapter()

        try await AdapterContractSuite.verify(
            adapter: adapter,
            fixtureScenario: "codex-basic",
            repoRelativePath: "repos/backend-api",
            corruptConfigRelativePath: ".codex/config.toml"
        )
        try await AdapterContractSuite.verify(
            adapter: adapter,
            fixtureScenario: "polyglot",
            repoRelativePath: "repos/demo-app",
            corruptConfigRelativePath: ".codex/config.toml"
        )
    }

    @Test("No raw agent path literals exist in Codex adapter sources outside CodexPathCatalog.swift")
    func noPathLiteralsOutsideCatalog() throws {
        let codexDir = FixtureHome.repositoryRoot()
            .appendingPathComponent("Sources/BentoAdapters/Codex", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: codexDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "CodexPathCatalog.swift" }

        let forbiddenLiterals = [
            "\".codex\"",
            "\".codex/",
            "\".agents\"",
            "\".agents/",
            "\"config.toml\"",
            "\"requirements.toml\"",
            "\"AGENTS.md\"",
            "\"AGENTS.override.md\"",
            "\"SKILL.md\"",
            "\"hooks.json\"",
            "\"etc/codex\""
        ]

        for fileURL in files {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for line in source.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                for literal in forbiddenLiterals {
                    #expect(
                        !trimmed.contains(literal),
                        "Found path literal \(literal) in \(fileURL.lastPathComponent); route through CodexPathCatalog"
                    )
                }
            }
        }
    }

    @Test("CODEX_HOME relocates user config, rules, skills, and rollout logs without touching ~/.codex")
    func codexHomeEnvOverride() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-codex-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let customCodex = tempRoot.appendingPathComponent("custom-codex-home", isDirectory: true)
        let skillDir = customCodex.appendingPathComponent("skills/custom-linter", isDirectory: true)
        let sessionDir = customCodex.appendingPathComponent("sessions/2026/10/30", isDirectory: true)
        let repoDir = tempRoot.appendingPathComponent("repo", isDirectory: true)

        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)

        try Data("model = \"gpt-5-codex\"\n".utf8).write(to: customCodex.appendingPathComponent("config.toml"))
        try Data("# Custom Codex Rules\n".utf8).write(to: customCodex.appendingPathComponent("AGENTS.md"))
        try Data("---\nname: custom-linter\ndescription: Custom CODEX_HOME skill\n---\nBody\n".utf8)
            .write(to: skillDir.appendingPathComponent("SKILL.md"))
        try Data("{\"type\":\"session_meta\"}\n".utf8)
            .write(to: sessionDir.appendingPathComponent("rollout-1.jsonl"))

        let env = AgentEnvironment(
            home: tempRoot,
            env: [
                "CODEX_HOME": customCodex.path,
                "BENTO_SYSTEM_ROOT": tempRoot.path
            ],
            fileSystem: LocalReadOnlyFileSystem(),
            now: { FixtureHome.defaultTimestamp }
        )

        let adapter = CodexAdapter()
        let detection = await adapter.detect(in: env)
        #expect(detection.isDetected)
        #expect(detection.detectedPaths.contains(customCodex.standardizedFileURL.path))

        let artifacts = try await adapter.discover(in: env, folder: repoDir)
        #expect(artifacts.contains { $0.kind == .settings && $0.scope == .user })
        #expect(artifacts.contains { $0.kind == .rules && $0.name == "AGENTS.md" && $0.scope == .user })
        #expect(artifacts.contains { $0.kind == .skill && $0.name == "custom-linter" && $0.scope == .user })

        let logs = try adapter.logSources(in: env)
        #expect(logs.count == 1)
        #expect(logs.first?.url.lastPathComponent == "rollout-1.jsonl")

        let fixes = adapter.fixSupport()
        #expect(!fixes.supportsAtImports)
        #expect(fixes.supportedKinds.contains(.disableMCPServer))
        #expect(!fixes.supportedKinds.contains(.replaceDuplicateRulesWithImport))
    }

    @Test("Untrusted project skips project .codex/config.toml, project MCP servers, and project hooks.json")
    func untrustedProjectSkipsProjectConfigAndHooks() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-codex-untrusted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let userCodex = tempRoot.appendingPathComponent(".codex", isDirectory: true)
        let repoDir = tempRoot.appendingPathComponent("repos/untrusted-repo", isDirectory: true)
        let repoCodex = repoDir.appendingPathComponent(".codex", isDirectory: true)

        try FileManager.default.createDirectory(at: userCodex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoCodex, withIntermediateDirectories: true)

        let userTOML = """
            [projects."~/repos/untrusted-repo"]
            trust_level = "untrusted"

            [mcp_servers.safe-user]
            command = "npx"
            args = ["-y", "@example/safe-mcp"]
            """
        try Data(userTOML.utf8).write(to: userCodex.appendingPathComponent("config.toml"))

        let projectTOML = """
            [mcp_servers.malicious-project]
            command = "sh"
            args = ["-c", "echo untrusted"]
            """
        try Data(projectTOML.utf8).write(to: repoCodex.appendingPathComponent("config.toml"))
        try Data(
            "{\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo bad\"}]}]}}\n".utf8
        )
        .write(to: repoCodex.appendingPathComponent("hooks.json"))

        let env = AgentEnvironment(
            home: tempRoot,
            env: ["BENTO_SYSTEM_ROOT": tempRoot.path],
            fileSystem: LocalReadOnlyFileSystem(),
            now: { FixtureHome.defaultTimestamp }
        )

        let adapter = CodexAdapter()
        let artifacts = try await adapter.discover(in: env, folder: repoDir)
        let resolution = adapter.resolve(artifacts, folder: repoDir, env: env)
        let byID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.id, $0) })

        let maliciousResolved = try #require(
            resolution.ordered.first { byID[$0.artifactID]?.name == "malicious-project" }
        )
        #expect(maliciousResolved.effectiveLoadMode == .never)

        let projectHookResolved = try #require(
            resolution.ordered.first {
                let item = byID[$0.artifactID]
                return item?.kind == .hook && item?.scope == .project
            }
        )
        #expect(projectHookResolved.effectiveLoadMode == .never)
        #expect(resolution.warnings.contains { $0.code == "codex.projectUntrusted" })
    }
}
