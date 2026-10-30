import BentoAdapters
import BentoCore
import BentoTestSupport
import Foundation
import Testing

struct CursorAdapterContractTests {
    @Test("CursorAdapter satisfies shared AdapterContractSuite on cursor-basic and polyglot")
    func contractSuitePassesFixtures() async throws {
        let adapter = CursorAdapter()

        try await AdapterContractSuite.verify(
            adapter: adapter,
            fixtureScenario: "cursor-basic",
            repoRelativePath: "repos/design-system",
            corruptConfigRelativePath: ".cursor/mcp.json"
        )
        try await AdapterContractSuite.verify(
            adapter: adapter,
            fixtureScenario: "polyglot",
            repoRelativePath: "repos/demo-app",
            corruptConfigRelativePath: ".cursor/mcp.json"
        )
    }

    @Test("CursorAdapter capabilities include only inventory and resolution (excluding budget and usageLogs)")
    func capabilitiesExcludeBudgetAndUsage() {
        let adapter = CursorAdapter()
        #expect(adapter.capabilities == [.inventory, .resolution])
        #expect(!adapter.capabilities.contains(.budget))
        #expect(!adapter.capabilities.contains(.usageLogs))
        #expect(!adapter.capabilities.contains(.fixes))
        #expect(adapter.builtInBudget(model: nil).isEmpty)
        #expect(adapter.fixSupport().supportedKinds.isEmpty)
        #expect(!adapter.fixSupport().supportsAtImports)
    }

    @Test("No raw agent path literals exist in Cursor adapter sources outside CursorPathCatalog.swift")
    func noPathLiteralsOutsideCatalog() throws {
        let cursorDir = FixtureHome.repositoryRoot()
            .appendingPathComponent("Sources/BentoAdapters/Cursor", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: cursorDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "CursorPathCatalog.swift" }

        let forbiddenLiterals = [
            "\".cursor\"",
            "\".cursor/",
            "\".cursorrules\"",
            "\".cursorignore\"",
            "\".cursorindexingignore\"",
            "\"mcp.json\"",
            "\"AGENTS.md\"",
            "\"SKILL.md\""
        ]

        for fileURL in files {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for line in source.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                for literal in forbiddenLiterals {
                    #expect(
                        !trimmed.contains(literal),
                        "Found path literal \(literal) in \(fileURL.lastPathComponent); route through CursorPathCatalog"
                    )
                }
            }
        }
    }
}
