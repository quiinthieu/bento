import BentoAdapters
import BentoCore
import BentoTestSupport
import Foundation
import Testing

struct ClaudeCodeAdapterContractTests {
    @Test("ClaudeCodeAdapter satisfies shared AdapterContractSuite across all Claude fixtures")
    func contractSuitePassesAllFixtures() async throws {
        let adapter = ClaudeCodeAdapter()

        try await AdapterContractSuite.verify(
            adapter: adapter,
            fixtureScenario: "claude-basic",
            repoRelativePath: "repos/webapp",
            corruptConfigRelativePath: ".claude/settings.json"
        )
        try await AdapterContractSuite.verify(
            adapter: adapter,
            fixtureScenario: "claude-plugins",
            repoRelativePath: "repos/service",
            corruptConfigRelativePath: ".claude/settings.json"
        )
        try await AdapterContractSuite.verify(
            adapter: adapter,
            fixtureScenario: "claude-precedence",
            repoRelativePath: "repos/payments",
            corruptConfigRelativePath: "repos/payments/.mcp.json"
        )
    }

    @Test("No raw agent path literals exist in ClaudeCode adapter sources outside ClaudeCodePathCatalog.swift")
    func noPathLiteralsOutsideCatalog() throws {
        let claudeDir = FixtureHome.repositoryRoot()
            .appendingPathComponent("Sources/BentoAdapters/ClaudeCode", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: claudeDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "ClaudeCodePathCatalog.swift" }

        let forbiddenLiterals = [
            "\".claude\"",
            "\".claude/",
            "\".claude.json\"",
            "\".mcp.json\"",
            "\"CLAUDE.md\"",
            "\"CLAUDE.local.md\"",
            "\"SKILL.md\"",
            "\"managed-settings.json\"",
            "\"managed-mcp.json\"",
            "\"installed_plugins.json\"",
            "\"plugin.json\"",
            "\"ClaudeCode\""
        ]

        for fileURL in files {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for line in source.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                for literal in forbiddenLiterals {
                    #expect(
                        !trimmed.contains(literal),
                        "Found path literal \(literal) in \(fileURL.lastPathComponent); route through ClaudeCodePathCatalog"
                    )
                }
            }
        }
    }

    @Test("CLAUDE_CONFIG_DIR relocates user config, skills, and logs without touching ~/.claude")
    func claudeConfigDirOverride() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-claude-config-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let customConfig = tempRoot.appendingPathComponent("custom-claude", isDirectory: true)
        let skillDir = customConfig.appendingPathComponent("skills/custom-skill", isDirectory: true)
        let logDir = customConfig.appendingPathComponent("projects/-repo", isDirectory: true)
        let repoDir = tempRoot.appendingPathComponent("repo", isDirectory: true)

        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)

        try Data("# Custom Global Memory\n".utf8).write(to: customConfig.appendingPathComponent("CLAUDE.md"))
        try Data("---\nname: custom-skill\ndescription: Custom dir skill\n---\nBody\n".utf8)
            .write(to: skillDir.appendingPathComponent("SKILL.md"))
        try Data("{\"type\":\"summary\"}\n".utf8)
            .write(to: logDir.appendingPathComponent("s1.jsonl"))

        let env = AgentEnvironment(
            home: tempRoot,
            env: [
                "CLAUDE_CONFIG_DIR": customConfig.path,
                "BENTO_SYSTEM_ROOT": tempRoot.path
            ],
            fileSystem: LocalReadOnlyFileSystem(),
            now: { FixtureHome.defaultTimestamp }
        )

        let adapter = ClaudeCodeAdapter()
        let detection = await adapter.detect(in: env)
        #expect(detection.isDetected)
        #expect(detection.detectedPaths.contains(customConfig.standardizedFileURL.path))

        let artifacts = try await adapter.discover(in: env, folder: repoDir)
        #expect(artifacts.contains { $0.kind == .rules && $0.name == "CLAUDE.md" && $0.scope == .user })
        #expect(artifacts.contains { $0.kind == .skill && $0.name == "custom-skill" && $0.scope == .user })

        let logs = try adapter.logSources(in: env)
        #expect(logs.count == 1)
        #expect(logs.first?.url.lastPathComponent == "s1.jsonl")

        let fixes = adapter.fixSupport()
        #expect(fixes.supportsAtImports)
        #expect(fixes.supportedKinds.contains(.disableMCPServer))
        #expect(fixes.supportedKinds.contains(.replaceDuplicateRulesWithImport))
    }
}
