import BentoAdapters
import BentoCore
import BentoTestSupport
import Foundation
import Testing

struct CopilotAdapterContractTests {
    @Test("CopilotAdapter satisfies shared AdapterContractSuite on copilot-basic and polyglot")
    func contractSuitePassesFixtures() async throws {
        let adapter = CopilotAdapter()

        try await AdapterContractSuite.verify(
            adapter: adapter,
            fixtureScenario: "copilot-basic",
            repoRelativePath: "repos/octocat-api",
            corruptConfigRelativePath: ".copilot/mcp-config.json"
        )
        try await AdapterContractSuite.verify(
            adapter: adapter,
            fixtureScenario: "polyglot",
            repoRelativePath: "repos/demo-app",
            corruptConfigRelativePath: ".copilot/mcp-config.json"
        )
    }

    @Test("No raw agent path literals exist in Copilot adapter sources outside CopilotPathCatalog.swift")
    func noPathLiteralsOutsideCatalog() throws {
        let copilotDir = FixtureHome.repositoryRoot()
            .appendingPathComponent("Sources/BentoAdapters/Copilot", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: copilotDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "CopilotPathCatalog.swift" }

        let forbiddenLiterals = [
            "\".copilot\"",
            "\".copilot/",
            "\".github\"",
            "\".github/",
            "\".vscode\"",
            "\".vscode/",
            "\".agents\"",
            "\".agents/",
            "\"copilot-instructions.md\"",
            "\".instructions.md\"",
            "\"mcp-config.json\"",
            "\"AGENTS.md\"",
            "\"SKILL.md\"",
            "\"events.jsonl\"",
            "\"workspace.yaml\""
        ]

        for fileURL in files {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for line in source.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                for literal in forbiddenLiterals {
                    #expect(
                        !trimmed.contains(literal),
                        "Found path literal \(literal) in \(fileURL.lastPathComponent); route through CopilotPathCatalog"
                    )
                }
            }
        }
    }

    @Test("COPILOT_HOME relocates user config, instructions, MCP servers, and session-state logs")
    func copilotHomeEnvOverride() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-copilot-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let customCopilot = tempRoot.appendingPathComponent("custom-copilot-home", isDirectory: true)
        let sessDir = customCopilot.appendingPathComponent("session-state/s-100", isDirectory: true)
        let repoDir = tempRoot.appendingPathComponent("repo", isDirectory: true)

        try FileManager.default.createDirectory(at: sessDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)

        try Data("{\"model\":\"gpt-5\"}\n".utf8)
            .write(to: customCopilot.appendingPathComponent("config.json"))
        try Data("# Custom Copilot Instructions\n".utf8)
            .write(to: customCopilot.appendingPathComponent("copilot-instructions.md"))
        try Data("{\"mcpServers\":{\"local-docs\":{\"command\":\"npx\",\"args\":[\"-y\",\"docs-mcp\"]}}}\n".utf8)
            .write(to: customCopilot.appendingPathComponent("mcp-config.json"))
        try Data("cwd: \"\(repoDir.standardizedFileURL.path)\"\n".utf8)
            .write(to: sessDir.appendingPathComponent("workspace.yaml"))
        try Data("{\"type\":\"session.start\"}\n".utf8)
            .write(to: sessDir.appendingPathComponent("events.jsonl"))

        let env = AgentEnvironment(
            home: tempRoot,
            env: [
                "COPILOT_HOME": customCopilot.path,
                "BENTO_SYSTEM_ROOT": tempRoot.path
            ],
            fileSystem: LocalReadOnlyFileSystem(),
            now: { FixtureHome.defaultTimestamp }
        )

        let adapter = CopilotAdapter()
        #expect(
            adapter.capabilities == [.inventory, .resolution, .budget, .usageLogs, .mcpProbe, .fixes]
        )

        let detection = await adapter.detect(in: env)
        #expect(detection.isDetected)
        #expect(detection.detectedPaths.contains(customCopilot.standardizedFileURL.path))

        let artifacts = try await adapter.discover(in: env, folder: repoDir)
        #expect(artifacts.contains { $0.kind == .settings && $0.name == "config.json" })
        #expect(artifacts.contains { $0.kind == .rules && $0.name == "copilot-instructions.md" })
        #expect(artifacts.contains { $0.kind == .mcpServer && $0.name == "local-docs" })

        let logs = try adapter.logSources(in: env)
        #expect(logs.count == 1)
        #expect(logs.first?.url.lastPathComponent == "events.jsonl")
        #expect(logs.first?.inferredCwd == repoDir.standardizedFileURL.path)

        let fixes = adapter.fixSupport()
        #expect(!fixes.supportsAtImports)
        #expect(fixes.supportedKinds == [.disableMCPServer, .enableMCPServer])
    }
}
