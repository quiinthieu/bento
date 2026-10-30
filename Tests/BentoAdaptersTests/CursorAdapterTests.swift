import BentoAdapters
import BentoCore
import BentoTestSupport
import Foundation
import Testing

struct CursorAdapterTests {
    @Test(
        "cursor-basic discovers .mdc activation modes, .cursorrules, AGENTS.md hierarchy, project/user mcp.json precedence, skills, subagents, ignore files, and matches goldens"
    )
    func cursorBasicInventoryAndResolution() async throws {
        let fixture = try FixtureHome(scenario: "cursor-basic")
        let env = fixture.makeEnvironment()
        let repoFolder = fixture.url.appendingPathComponent("repos/design-system", isDirectory: true)
        let adapter = CursorAdapter()

        let artifacts = try await adapter.discover(in: env, folder: repoFolder)
        let resolution = adapter.resolve(artifacts, folder: repoFolder, env: env)

        // Secret redaction check: MCP env/header secret values are stripped while env key names remain
        let encodedInventory = try GoldenFile.encodeCanonicalJSON(artifacts, homeURL: fixture.url)
        #expect(!encodedInventory.contains("TEST_SYNTHETIC_CURSOR_FIGMA_TOKEN"))
        #expect(!encodedInventory.contains("TEST_SYNTHETIC_CURSOR_LINEAR_TOKEN"))
        #expect(!encodedInventory.contains("TEST_SYNTHETIC_PROJECT_FIGMA_TOKEN"))
        #expect(encodedInventory.contains("FIGMA_ACCESS_TOKEN"))

        // .mdc activation modes
        let coreStyle = try #require(
            artifacts.first { $0.kind == .rules && $0.location.path.hasSuffix("core-style.mdc") }
        )
        #expect(coreStyle.loadMode == .always)

        let reactRule = try #require(
            artifacts.first { $0.kind == .rules && $0.location.path.hasSuffix("react-components.mdc") }
        )
        #expect(
            reactRule.loadMode
                == .conditional(globs: ["packages/ui/**/*.tsx", "packages/ui/**/*.ts"])
        )

        let migrationRule = try #require(
            artifacts.first { $0.kind == .rules && $0.location.path.hasSuffix("migration-guide.mdc") }
        )
        #expect(migrationRule.loadMode == .onInvoke)

        // Legacy .cursorrules and AGENTS.md
        #expect(artifacts.contains { $0.kind == .rules && $0.name == ".cursorrules" && $0.loadMode == .always })
        #expect(artifacts.contains { $0.kind == .rules && $0.scope == .project && $0.name == "AGENTS.md" })

        let iconsAgents = try #require(
            artifacts.first { $0.kind == .rules && $0.location.path.hasSuffix("packages/icons/AGENTS.md") }
        )
        let iconsAtRoot = try #require(resolution.ordered.first { $0.artifactID == iconsAgents.id })
        #expect(iconsAtRoot.effectiveLoadMode == .conditional(globs: ["packages/icons/**"]))

        let iconsFolder = repoFolder.appendingPathComponent("packages/icons", isDirectory: true)
        let iconsResolution = adapter.resolve(artifacts, folder: iconsFolder, env: env)
        let iconsInSubdir = try #require(iconsResolution.ordered.first { $0.artifactID == iconsAgents.id })
        #expect(iconsInSubdir.effectiveLoadMode == .always)

        // MCP precedence: project .cursor/mcp.json figma shadows user ~/.cursor/mcp.json figma
        let projectFigma = try #require(
            artifacts.first { $0.kind == .mcpServer && $0.name == "figma" && $0.scope == .project }
        )
        let userFigma = try #require(
            artifacts.first { $0.kind == .mcpServer && $0.name == "figma" && $0.scope == .user }
        )
        #expect(
            resolution.shadowed.contains {
                $0.shadowedArtifactID == userFigma.id && $0.winningArtifactID == projectFigma.id
            }
        )

        let linear = try #require(artifacts.first { $0.kind == .mcpServer && $0.name == "linear" })
        if case .mcpServer(let cfg) = linear.payload {
            #expect(cfg.transport == .sse(url: "https://mcp.linear.example.test/sse"))
        } else {
            Issue.record("Expected MCPServerConfig on linear")
        }

        // Skills: project component-audit shadows user component-audit
        let projectAudit = try #require(
            artifacts.first { $0.kind == .skill && $0.name == "component-audit" && $0.scope == .project }
        )
        let userAudit = try #require(
            artifacts.first { $0.kind == .skill && $0.name == "component-audit" && $0.scope == .user }
        )
        #expect(
            resolution.shadowed.contains {
                $0.shadowedArtifactID == userAudit.id && $0.winningArtifactID == projectAudit.id
            }
        )

        // Subagents & ignore files
        #expect(artifacts.filter { $0.kind == .subagent }.count == 2)
        #expect(artifacts.contains { $0.kind == .ignoreFile && $0.name == ".cursorignore" })
        #expect(artifacts.contains { $0.kind == .ignoreFile && $0.name == ".cursorindexingignore" })
        #expect(try adapter.logSources(in: env).isEmpty)

        try GoldenFile.assertMatches(
            artifacts,
            goldenURL: Self.goldenURL("cursor-basic-inventory.json"),
            homeURL: fixture.url
        )
        try GoldenFile.assertMatches(
            resolution,
            goldenURL: Self.goldenURL("cursor-basic-resolution.json"),
            homeURL: fixture.url
        )
    }

    private static func goldenURL(_ filename: String) -> URL {
        FixtureHome.repositoryRoot()
            .appendingPathComponent("Tests/BentoAdaptersTests/__golden__", isDirectory: true)
            .appendingPathComponent(filename)
    }
}
