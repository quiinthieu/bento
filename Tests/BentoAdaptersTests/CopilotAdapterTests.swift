import BentoAdapters
import BentoCore
import BentoTestSupport
import Foundation
import Testing

struct CopilotAdapterTests {
    @Test(
        "copilot-basic discovers instructions, applyTo conditional rules, AGENTS.md hierarchy, .github/.vscode/user MCP precedence, skills, custom agents, prompt commands, hooks, and matches goldens"
    )
    func copilotBasicInventoryAndResolution() async throws {
        let fixture = try FixtureHome(scenario: "copilot-basic")
        let env = fixture.makeEnvironment()
        let repoFolder = fixture.url.appendingPathComponent("repos/octocat-api", isDirectory: true)
        let adapter = CopilotAdapter()

        let artifacts = try await adapter.discover(in: env, folder: repoFolder)
        let resolution = adapter.resolve(artifacts, folder: repoFolder, env: env)

        // Secret redaction check
        let encodedInventory = try GoldenFile.encodeCanonicalJSON(artifacts, homeURL: fixture.url)
        #expect(!encodedInventory.contains("TEST_SYNTHETIC_COPILOT_TOKEN_PLACEHOLDER"))
        #expect(!encodedInventory.contains("TEST_SYNTHETIC_COPILOT_PAT_PLACEHOLDER"))
        #expect(!encodedInventory.contains("TEST_SYNTHETIC_COPILOT_BEARER"))
        #expect(encodedInventory.contains("«redacted»"))

        let byID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.id, $0) })

        // Global & repo copilot-instructions.md are always loaded
        let userInstructions = try #require(
            artifacts.first { $0.kind == .rules && $0.scope == .user && $0.name == "copilot-instructions.md" }
        )
        #expect(userInstructions.loadMode == .always)

        let repoInstructions = try #require(
            artifacts.first {
                $0.kind == .rules && $0.scope == .project
                    && $0.location.path.hasSuffix(".github/copilot-instructions.md")
            }
        )
        #expect(repoInstructions.loadMode == .always)

        // Modular .instructions.md with applyTo -> LoadMode.conditional(globs:)
        let swiftInstr = try #require(
            artifacts.first { $0.kind == .rules && $0.location.path.hasSuffix("swift.instructions.md") }
        )
        #expect(swiftInstr.loadMode == .conditional(globs: ["Sources/**/*.swift", "Tests/**/*.swift"]))
        let resolvedSwiftInstr = try #require(resolution.ordered.first { $0.artifactID == swiftInstr.id })
        #expect(resolvedSwiftInstr.effectiveLoadMode == .conditional(globs: ["Sources/**/*.swift", "Tests/**/*.swift"]))

        let sqlInstr = try #require(
            artifacts.first { $0.kind == .rules && $0.location.path.hasSuffix("migrations.instructions.md") }
        )
        #expect(sqlInstr.loadMode == .conditional(globs: ["db/migrations/**/*.sql"]))

        // Nested services/billing/AGENTS.md is conditional at repo root, and always inside services/billing/
        let billingAgents = try #require(
            artifacts.first { $0.kind == .rules && $0.location.path.hasSuffix("services/billing/AGENTS.md") }
        )
        let billingAtRoot = try #require(resolution.ordered.first { $0.artifactID == billingAgents.id })
        #expect(billingAtRoot.effectiveLoadMode == .conditional(globs: ["services/billing/**"]))

        let billingFolder = repoFolder.appendingPathComponent("services/billing", isDirectory: true)
        let billingResolution = adapter.resolve(artifacts, folder: billingFolder, env: env)
        let billingInSubdir = try #require(billingResolution.ordered.first { $0.artifactID == billingAgents.id })
        #expect(billingInSubdir.effectiveLoadMode == .always)

        // MCP precedence: .github/mcp.json > .vscode/mcp.json > ~/.copilot/mcp-config.json
        let githubObs = try #require(
            artifacts.first {
                $0.kind == .mcpServer && $0.name == "observability" && $0.location.path.hasSuffix(".github/mcp.json")
            }
        )
        if case .mcpServer(let obsCfg) = githubObs.payload {
            #expect(obsCfg.transport == .http(url: "https://telemetry.octocat-api.example.test/mcp"))
            #expect(obsCfg.allowedTools == ["query_metrics", "trace_request"])
        } else {
            Issue.record("Expected MCPServerConfig on .github/mcp.json observability")
        }
        let obsShadows = resolution.shadowed.filter { $0.winningArtifactID == githubObs.id }
        #expect(obsShadows.count == 2)

        // tools: ["*"] maps to allowedTools == nil; VS Code "servers" key discovers openapi-preview
        let personalGH = try #require(artifacts.first { $0.kind == .mcpServer && $0.name == "github-personal" })
        if case .mcpServer(let ghCfg) = personalGH.payload {
            #expect(ghCfg.allowedTools == nil)
            #expect(ghCfg.envKeys == ["GITHUB_PERSONAL_ACCESS_TOKEN"])
        } else {
            Issue.record("Expected MCPServerConfig on github-personal")
        }
        #expect(artifacts.contains { $0.kind == .mcpServer && $0.name == "openapi-preview" })

        let legacyDBResolved = try #require(
            resolution.ordered.first { byID[$0.artifactID]?.name == "legacy-db" }
        )
        #expect(legacyDBResolved.effectiveLoadMode == .never)

        // Skills: ~/.agents/skills/pr-triage shadows ~/.copilot/skills/pr-triage
        let prSkills = artifacts.filter { $0.kind == .skill && $0.name == "pr-triage" }
        #expect(prSkills.count == 2)
        let agentsPR = try #require(prSkills.first { $0.location.path.contains("/.agents/skills/") })
        let copilotPR = try #require(prSkills.first { $0.location.path.contains("/.copilot/skills/") })
        #expect(
            resolution.shadowed.contains {
                $0.shadowedArtifactID == copilotPR.id && $0.winningArtifactID == agentsPR.id
            }
        )
        #expect(artifacts.contains { $0.kind == .skill && $0.name == "api-contract" && $0.scope == .project })

        // Custom agents: .github/agents/security-reviewer.agent.md shadows ~/.copilot/agents/security-reviewer.agent.md
        let projectSec = try #require(
            artifacts.first { $0.kind == .subagent && $0.name == "security-reviewer" && $0.scope == .project }
        )
        let userSec = try #require(
            artifacts.first { $0.kind == .subagent && $0.name == "security-reviewer" && $0.scope == .user }
        )
        #expect(
            resolution.shadowed.contains {
                $0.shadowedArtifactID == userSec.id && $0.winningArtifactID == projectSec.id
            }
        )

        // Prompt command & hooks
        #expect(artifacts.contains { $0.kind == .command && $0.name == "release-notes" })
        let hooks = artifacts.filter { $0.kind == .hook }
        #expect(hooks.count == 3)

        // Session logs
        let logs = try adapter.logSources(in: env)
        #expect(logs.count == 1)
        #expect(logs.first?.inferredCwd == repoFolder.standardizedFileURL.path)

        try GoldenFile.assertMatches(
            artifacts,
            goldenURL: Self.goldenURL("copilot-basic-inventory.json"),
            homeURL: fixture.url
        )
        try GoldenFile.assertMatches(
            resolution,
            goldenURL: Self.goldenURL("copilot-basic-resolution.json"),
            homeURL: fixture.url
        )
    }

    private static func goldenURL(_ filename: String) -> URL {
        FixtureHome.repositoryRoot()
            .appendingPathComponent("Tests/BentoAdaptersTests/__golden__", isDirectory: true)
            .appendingPathComponent(filename)
    }
}
