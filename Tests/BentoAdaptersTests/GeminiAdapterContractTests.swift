import BentoAdapters
import BentoCore
import BentoTestSupport
import Foundation
import Testing

struct GeminiAdapterContractTests {
    @Test("GeminiAdapter satisfies shared AdapterContractSuite on gemini-basic and polyglot")
    func contractSuitePassesFixtures() async throws {
        let adapter = GeminiAdapter()

        try await AdapterContractSuite.verify(
            adapter: adapter,
            fixtureScenario: "gemini-basic",
            repoRelativePath: "repos/storefront",
            corruptConfigRelativePath: ".gemini/settings.json"
        )
        try await AdapterContractSuite.verify(
            adapter: adapter,
            fixtureScenario: "polyglot",
            repoRelativePath: "repos/demo-app",
            corruptConfigRelativePath: ".gemini/settings.json"
        )
    }

    @Test("No raw agent path literals exist in Gemini adapter sources outside GeminiPathCatalog.swift")
    func noPathLiteralsOutsideCatalog() throws {
        let geminiDir = FixtureHome.repositoryRoot()
            .appendingPathComponent("Sources/BentoAdapters/Gemini", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: geminiDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "GeminiPathCatalog.swift" }

        let forbiddenLiterals = [
            "\".gemini\"",
            "\".gemini/",
            "\".geminiignore\"",
            "\".agents\"",
            "\".agents/",
            "\"GEMINI.md\"",
            "\"SKILL.md\"",
            "\"settings.json\"",
            "\"system-defaults.json\"",
            "\"gemini-extension.json\"",
            "\"extension-enablement.json\"",
            "\"GeminiCli\""
        ]

        for fileURL in files {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for line in source.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                for literal in forbiddenLiterals {
                    #expect(
                        !trimmed.contains(literal),
                        "Found path literal \(literal) in \(fileURL.lastPathComponent); route through GeminiPathCatalog"
                    )
                }
            }
        }
    }

    @Test("GEMINI_CLI_HOME and GEMINI_CLI_SYSTEM_SETTINGS_PATH relocate user and system config paths")
    func geminiEnvOverrides() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-gemini-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let customGemini = tempRoot.appendingPathComponent("custom-gemini-dir", isDirectory: true)
        let cmdDir = customGemini.appendingPathComponent("commands/ops", isDirectory: true)
        let chatDir = customGemini.appendingPathComponent("tmp/hash123/chats", isDirectory: true)
        let sysDir = tempRoot.appendingPathComponent("custom-sys", isDirectory: true)
        let repoDir = tempRoot.appendingPathComponent("repo", isDirectory: true)

        try FileManager.default.createDirectory(at: cmdDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sysDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)

        let sysSettingsFile = sysDir.appendingPathComponent("corp-settings.json")
        try Data("{\"security\":{\"disableYoloMode\":true}}\n".utf8).write(to: sysSettingsFile)
        try Data("{\"general\":{\"vimMode\":true}}\n".utf8).write(
            to: customGemini.appendingPathComponent("settings.json"))
        try Data("# Custom Gemini Context\n".utf8).write(to: customGemini.appendingPathComponent("GEMINI.md"))
        try Data("description = \"Rotate keys\"\nprompt = \"Rotate service credentials\"\n".utf8)
            .write(to: cmdDir.appendingPathComponent("rotate.toml"))
        try Data("{\"sessionId\":\"s1\"}\n".utf8)
            .write(to: chatDir.appendingPathComponent("session-001.json"))

        let env = AgentEnvironment(
            home: tempRoot,
            env: [
                "GEMINI_CLI_HOME": customGemini.path,
                "GEMINI_CLI_SYSTEM_SETTINGS_PATH": sysSettingsFile.path,
                "BENTO_SYSTEM_ROOT": tempRoot.path
            ],
            fileSystem: LocalReadOnlyFileSystem(),
            now: { FixtureHome.defaultTimestamp }
        )

        let adapter = GeminiAdapter()
        let detection = await adapter.detect(in: env)
        #expect(detection.isDetected)
        #expect(detection.detectedPaths.contains(customGemini.standardizedFileURL.path))

        let artifacts = try await adapter.discover(in: env, folder: repoDir)
        #expect(artifacts.contains { $0.kind == .settings && $0.scope == .managed })
        #expect(artifacts.contains { $0.kind == .settings && $0.scope == .user })
        #expect(artifacts.contains { $0.kind == .rules && $0.name == "GEMINI.md" && $0.scope == .user })
        #expect(artifacts.contains { $0.kind == .command && $0.name == "ops:rotate" && $0.scope == .user })

        let logs = try adapter.logSources(in: env)
        #expect(logs.count == 1)
        #expect(logs.first?.url.lastPathComponent == "session-001.json")

        let fixes = adapter.fixSupport()
        #expect(fixes.supportsAtImports)
        #expect(fixes.supportedKinds.contains(.replaceDuplicateRulesWithImport))
        #expect(fixes.supportedKinds.contains(.disableMCPServer))
    }
}
