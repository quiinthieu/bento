import BentoAdapters
import BentoCore
import BentoTestSupport
import Foundation
import Testing

struct WindsurfAdapterContractTests {
    @Test("WindsurfAdapter satisfies shared AdapterContractSuite on windsurf-limits and polyglot")
    func contractSuitePassesFixtures() async throws {
        let adapter = WindsurfAdapter()

        try await AdapterContractSuite.verify(
            adapter: adapter,
            fixtureScenario: "windsurf-limits",
            repoRelativePath: "repos/cascade-app",
            corruptConfigRelativePath: ".codeium/windsurf/mcp_config.json"
        )
        try await AdapterContractSuite.verify(
            adapter: adapter,
            fixtureScenario: "polyglot",
            repoRelativePath: "repos/demo-app",
            corruptConfigRelativePath: ".codeium/windsurf/mcp_config.json"
        )
    }

    @Test("WindsurfAdapter capabilities include only inventory and resolution (excluding budget and usageLogs)")
    func capabilitiesExcludeBudgetAndUsage() {
        let adapter = WindsurfAdapter()
        #expect(adapter.capabilities == [.inventory, .resolution])
        #expect(!adapter.capabilities.contains(.budget))
        #expect(!adapter.capabilities.contains(.usageLogs))
        #expect(!adapter.capabilities.contains(.fixes))
        #expect(adapter.builtInBudget(model: nil).isEmpty)
        #expect(adapter.fixSupport().supportedKinds.isEmpty)
        #expect(!adapter.fixSupport().supportsAtImports)
    }

    @Test("No raw agent path literals exist in Windsurf adapter sources outside WindsurfPathCatalog.swift")
    func noPathLiteralsOutsideCatalog() throws {
        let windsurfDir = FixtureHome.repositoryRoot()
            .appendingPathComponent("Sources/BentoAdapters/Windsurf", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: windsurfDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "WindsurfPathCatalog.swift" }

        let forbiddenLiterals = [
            "\".codeium\"",
            "\".codeium/",
            "\".windsurf\"",
            "\".windsurf/",
            "\".windsurfrules\"",
            "\".codeiumignore\"",
            "\"global_rules.md\"",
            "\"mcp_config.json\"",
            "\"AGENTS.md\""
        ]

        for fileURL in files {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for line in source.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                for literal in forbiddenLiterals {
                    #expect(
                        !trimmed.contains(literal),
                        "Found path literal \(literal) in \(fileURL.lastPathComponent); route through WindsurfPathCatalog"
                    )
                }
            }
        }
    }
}
