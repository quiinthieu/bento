import BentoAdapters
import BentoCore
import BentoTestSupport
import Foundation
import Testing

struct CodexAdapterTests {
    @Test(
        "codex-basic discovers config tiers, MCP servers, AGENTS.override.md shadowing, fallback rules, byte-cap truncation, skills, hooks, and matches goldens"
    )
    func codexBasicInventoryAndResolution() async throws {
        let fixture = try FixtureHome(scenario: "codex-basic")
        let env = fixture.makeEnvironment()
        let repoFolder = fixture.url.appendingPathComponent("repos/backend-api", isDirectory: true)
        let adapter = CodexAdapter()

        let artifacts = try await adapter.discover(in: env, folder: repoFolder)
        let resolution = adapter.resolve(artifacts, folder: repoFolder, env: env)

        // Secret redaction check
        let encodedInventory = try GoldenFile.encodeCanonicalJSON(artifacts, homeURL: fixture.url)
        #expect(!encodedInventory.contains("TEST_SYNTHETIC_CODEX_KEY_PLACEHOLDER"))
        #expect(!encodedInventory.contains("TEST_SYNTHETIC_TOKEN_PLACEHOLDER"))
        #expect(encodedInventory.contains("«redacted»"))

        let byID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.id, $0) })

        // AGENTS.override.md shadows AGENTS.md in the same directory (repos/backend-api)
        let repoStandardAgents = try #require(
            artifacts.first {
                $0.kind == .rules && $0.scope == .project && $0.name == "AGENTS.md"
            }
        )
        let repoOverrideAgents = try #require(
            artifacts.first {
                $0.kind == .rules && $0.scope == .project && $0.name == "AGENTS.override.md"
            }
        )
        #expect(
            resolution.shadowed.contains {
                $0.shadowedArtifactID == repoStandardAgents.id && $0.winningArtifactID == repoOverrideAgents.id
            }
        )
        #expect(!resolution.ordered.contains { $0.artifactID == repoStandardAgents.id })
        #expect(resolution.ordered.contains { $0.artifactID == repoOverrideAgents.id })

        // project_doc_max_bytes = 150 truncates cumulative chain (global AGENTS.md + repo AGENTS.override.md > 150 B)
        if case .rules(let overrideDoc) = repoOverrideAgents.payload {
            #expect(overrideDoc.wasTruncated)
        } else {
            Issue.record("Expected RulesDoc payload on AGENTS.override.md")
        }
        #expect(resolution.warnings.contains { $0.code == "rules.truncated" })

        // Fallback filename TEAM_GUIDE.md in services/auth is conditional at repo root, and always in services/auth
        let teamGuide = try #require(
            artifacts.first { $0.kind == .rules && $0.name.hasSuffix("TEAM_GUIDE.md") }
        )
        let teamGuideAtRoot = try #require(resolution.ordered.first { $0.artifactID == teamGuide.id })
        #expect(teamGuideAtRoot.effectiveLoadMode == .conditional(globs: ["services/auth/**"]))

        let authFolder = repoFolder.appendingPathComponent("services/auth", isDirectory: true)
        let authArtifacts = try await adapter.discover(in: env, folder: authFolder)
        let authResolution = adapter.resolve(authArtifacts, folder: authFolder, env: env)
        let authTeamGuide = try #require(
            authArtifacts.first { $0.kind == .rules && $0.name.hasSuffix("TEAM_GUIDE.md") }
        )
        let teamGuideInAuth = try #require(authResolution.ordered.first { $0.artifactID == authTeamGuide.id })
        // Since project_doc_max_bytes = 150 is already exhausted before services/auth, effectiveLoadMode is .never
        #expect(teamGuideInAuth.effectiveLoadMode == .never)
        #expect(teamGuideInAuth.reason.contains("project_doc_max_bytes"))

        // MCP servers: managed corp-audit (HTTP + bearer_token_env_var), project github shadows user github, disabled legacy-search
        let corpAudit = try #require(artifacts.first { $0.kind == .mcpServer && $0.name == "corp-audit" })
        if case .mcpServer(let cfg) = corpAudit.payload {
            #expect(cfg.transport == .http(url: "https://mcp.corp.example.test/v1"))
            #expect(cfg.envKeys == ["CORP_AUDIT_TOKEN"])
            #expect(cfg.allowedTools == ["audit_log"])
        } else {
            Issue.record("Expected MCPServerConfig on corp-audit")
        }

        let projectGithub = try #require(
            artifacts.first { $0.kind == .mcpServer && $0.name == "github" && $0.scope == .project }
        )
        let userGithub = try #require(
            artifacts.first { $0.kind == .mcpServer && $0.name == "github" && $0.scope == .user }
        )
        #expect(
            resolution.shadowed.contains {
                $0.shadowedArtifactID == userGithub.id && $0.winningArtifactID == projectGithub.id
            }
        )
        if case .mcpServer(let ghCfg) = projectGithub.payload {
            #expect(ghCfg.allowedTools == ["get_issue", "list_pulls"])
            #expect(ghCfg.disabledTools == ["merge_pull_request"])
        } else {
            Issue.record("Expected MCPServerConfig on project github")
        }

        let legacyResolved = try #require(
            resolution.ordered.first { byID[$0.artifactID]?.name == "legacy-search" }
        )
        #expect(legacyResolved.effectiveLoadMode == .never)

        // Skills: project .agents/skills/release-check shadows user release-check; user .agents/skills/sql-helper shadows .codex/skills/sql-helper; builtIn .system/skill-creator discovered
        let skillCreator = try #require(artifacts.first { $0.kind == .skill && $0.name == "skill-creator" })
        #expect(skillCreator.scope == .builtIn)

        let sqlSkills = artifacts.filter { $0.kind == .skill && $0.name == "sql-helper" }
        #expect(sqlSkills.count == 2)
        let agentsSQL = try #require(sqlSkills.first { $0.location.path.contains("/.agents/skills/") })
        let codexSQL = try #require(sqlSkills.first { $0.location.path.contains("/.codex/skills/") })
        #expect(
            resolution.shadowed.contains {
                $0.shadowedArtifactID == codexSQL.id && $0.winningArtifactID == agentsSQL.id
            }
        )
        if case .skill(let sqlDoc) = agentsSQL.payload {
            #expect(sqlDoc.supportingFiles == ["scripts/explain.sql"])
        } else {
            Issue.record("Expected SkillDoc on sql-helper")
        }

        // Hooks: managed hooks.json + user hooks.json + user config.toml [hooks].notify + project hooks.json
        let hooks = artifacts.filter { $0.kind == .hook }
        #expect(hooks.count == 4)

        // Rollout logs (.jsonl and .jsonl.zst)
        let logs = try adapter.logSources(in: env)
        #expect(logs.count == 2)
        #expect(logs.contains { !$0.isCompressed && $0.url.lastPathComponent.hasSuffix(".jsonl") })
        #expect(logs.contains { $0.isCompressed && $0.url.lastPathComponent.hasSuffix(".jsonl.zst") })

        try GoldenFile.assertMatches(
            artifacts,
            goldenURL: Self.goldenURL("codex-basic-inventory.json"),
            homeURL: fixture.url
        )
        try GoldenFile.assertMatches(
            resolution,
            goldenURL: Self.goldenURL("codex-basic-resolution.json"),
            homeURL: fixture.url
        )
    }

    private static func goldenURL(_ filename: String) -> URL {
        FixtureHome.repositoryRoot()
            .appendingPathComponent("Tests/BentoAdaptersTests/__golden__", isDirectory: true)
            .appendingPathComponent(filename)
    }
}
