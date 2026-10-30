import BentoAdapters
import BentoCore
import BentoTestSupport
import Foundation
import Testing

struct GeminiAdapterTests {
    @Test(
        "gemini-basic discovers 4 settings tiers, context.fileName hierarchy + @imports, MCP exclusions/precedence, .agents/skills alias, TOML commands, subagents, extensions, hooks, .geminiignore, and matches goldens"
    )
    func geminiBasicInventoryAndResolution() async throws {
        let fixture = try FixtureHome(scenario: "gemini-basic")
        let env = fixture.makeEnvironment()
        let repoFolder = fixture.url.appendingPathComponent("repos/storefront", isDirectory: true)
        let adapter = GeminiAdapter()

        let artifacts = try await adapter.discover(in: env, folder: repoFolder)
        let resolution = adapter.resolve(artifacts, folder: repoFolder, env: env)

        // Secret redaction check
        let encodedInventory = try GoldenFile.encodeCanonicalJSON(artifacts, homeURL: fixture.url)
        #expect(!encodedInventory.contains("TEST_SYNTHETIC_GEMINI_BEARER"))
        #expect(!encodedInventory.contains("TEST_SYNTHETIC_GEMINI_KEY_PLACEHOLDER"))
        #expect(!encodedInventory.contains("TEST_SYNTHETIC_EXT_SECRET_PLACEHOLDER"))
        #expect(encodedInventory.contains("«redacted»"))

        let byID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.id, $0) })

        // 4 settings tiers ordered base -> override: builtIn (system-defaults) -> user -> project -> managed (system settings)
        let resolvedSettingsScopes = resolution.ordered.compactMap { item -> Scope? in
            guard let art = byID[item.artifactID], art.kind == .settings else { return nil }
            return art.scope
        }
        #expect(resolvedSettingsScopes == [.builtIn, .user, .project, .managed])

        // context.fileName = ["AGENTS.md", "GEMINI.md"] + @./shared-style.md import + CLOUD.md extension context
        let userMemory = try #require(
            artifacts.first { $0.kind == .rules && $0.scope == .user && $0.name == "GEMINI.md" }
        )
        if case .rules(let doc) = userMemory.payload {
            #expect(doc.imports == ["./shared-style.md"])
        } else {
            Issue.record("Expected RulesDoc on user GEMINI.md")
        }
        #expect(artifacts.contains { $0.kind == .rules && $0.name == "shared-style.md" })
        #expect(artifacts.contains { $0.kind == .rules && $0.scope == .project && $0.name == "AGENTS.md" })
        #expect(artifacts.contains { $0.kind == .rules && $0.scope == .project && $0.name == "GEMINI.md" })
        #expect(artifacts.contains { $0.kind == .rules && $0.name == "CLOUD.md" })

        // JIT child checkout/GEMINI.md is conditional at repo root, and always when resolved from checkout/
        let checkoutRule = try #require(
            artifacts.first { $0.kind == .rules && $0.location.path.hasSuffix("checkout/GEMINI.md") }
        )
        let checkoutAtRoot = try #require(resolution.ordered.first { $0.artifactID == checkoutRule.id })
        #expect(checkoutAtRoot.effectiveLoadMode == .conditional(globs: ["checkout/**"]))

        let checkoutFolder = repoFolder.appendingPathComponent("checkout", isDirectory: true)
        let checkoutResolution = adapter.resolve(artifacts, folder: checkoutFolder, env: env)
        let checkoutInSubdir = try #require(checkoutResolution.ordered.first { $0.artifactID == checkoutRule.id })
        #expect(checkoutInSubdir.effectiveLoadMode == .always)

        // MCP servers: project docs shadows user docs, system-defaults docs, and extension docs; experimental-mcp excluded; corp-policy httpUrl
        let corpPolicy = try #require(artifacts.first { $0.kind == .mcpServer && $0.name == "corp-policy" })
        if case .mcpServer(let policyCfg) = corpPolicy.payload {
            #expect(policyCfg.transport == .http(url: "https://policy.corp.example.test/mcp"))
        } else {
            Issue.record("Expected MCPServerConfig on corp-policy")
        }

        let projectDocs = try #require(
            artifacts.first { $0.kind == .mcpServer && $0.name == "docs" && $0.scope == .project }
        )
        if case .mcpServer(let docsCfg) = projectDocs.payload {
            #expect(docsCfg.allowedTools == ["search_docs"])
            #expect(docsCfg.disabledTools == ["delete_doc"])
        } else {
            Issue.record("Expected MCPServerConfig on project docs")
        }
        let docsShadows = resolution.shadowed.filter { $0.winningArtifactID == projectDocs.id }
        #expect(docsShadows.count == 3)

        let experimentalResolved = try #require(
            resolution.ordered.first { byID[$0.artifactID]?.name == "experimental-mcp" }
        )
        #expect(experimentalResolved.effectiveLoadMode == .never)
        #expect(experimentalResolved.reason.contains("mcp.excluded"))

        // Skills: ~/.agents/skills/pr-review shadows ~/.gemini/skills/pr-review
        let prSkills = artifacts.filter { $0.kind == .skill && $0.name == "pr-review" }
        #expect(prSkills.count == 2)
        let agentsPR = try #require(prSkills.first { $0.location.path.contains("/.agents/skills/") })
        let geminiPR = try #require(prSkills.first { $0.location.path.contains("/.gemini/skills/") })
        #expect(
            resolution.shadowed.contains {
                $0.shadowedArtifactID == geminiPR.id && $0.winningArtifactID == agentsPR.id
            }
        )

        // Extensions: cloud-tools enabled, disabled-ext disabled via extension-enablement.json
        let cloudExt = try #require(artifacts.first { $0.kind == .plugin && $0.name == "cloud-tools" })
        #expect(cloudExt.enabled)
        let disabledExt = try #require(artifacts.first { $0.kind == .plugin && $0.name == "disabled-ext" })
        #expect(!disabledExt.enabled)
        let unusedExtSkill = try #require(artifacts.first { $0.kind == .skill && $0.name == "unused-ext-skill" })
        #expect(!unusedExtSkill.enabled)

        // Commands: TOML namespacing (git:commit, logs:tail) and project deploy shadowing user deploy
        #expect(artifacts.contains { $0.kind == .command && $0.name == "git:commit" })
        #expect(artifacts.contains { $0.kind == .command && $0.name == "logs:tail" })
        let projectDeploy = try #require(
            artifacts.first { $0.kind == .command && $0.name == "deploy" && $0.scope == .project }
        )
        let userDeploy = try #require(
            artifacts.first { $0.kind == .command && $0.name == "deploy" && $0.scope == .user }
        )
        #expect(
            resolution.shadowed.contains {
                $0.shadowedArtifactID == userDeploy.id && $0.winningArtifactID == projectDeploy.id
            }
        )

        // Subagents: checkout-auditor (project), architecture-critic (user), incident-responder (extension)
        let subagents = artifacts.filter { $0.kind == .subagent }
        #expect(subagents.count == 3)

        // Hooks: millisecond timeout 30000 -> 30 seconds, 15000 -> 15 seconds
        let userHook = try #require(
            artifacts.first { $0.kind == .hook && $0.name.contains("BeforeTool") }
        )
        if case .hook(let hCfg) = userHook.payload {
            #expect(hCfg.timeoutSeconds == 30)
        } else {
            Issue.record("Expected HookConfig on BeforeTool")
        }

        // Ignore file: .geminiignore
        #expect(artifacts.contains { $0.kind == .ignoreFile && $0.name == ".geminiignore" })

        // Session logs under ~/.gemini/tmp/<hash>/chats/
        let logs = try adapter.logSources(in: env)
        #expect(logs.count == 1)

        try GoldenFile.assertMatches(
            artifacts,
            goldenURL: Self.goldenURL("gemini-basic-inventory.json"),
            homeURL: fixture.url
        )
        try GoldenFile.assertMatches(
            resolution,
            goldenURL: Self.goldenURL("gemini-basic-resolution.json"),
            homeURL: fixture.url
        )
    }

    private static func goldenURL(_ filename: String) -> URL {
        FixtureHome.repositoryRoot()
            .appendingPathComponent("Tests/BentoAdaptersTests/__golden__", isDirectory: true)
            .appendingPathComponent(filename)
    }
}
