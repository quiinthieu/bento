import BentoAdapters
import BentoCore
import BentoTestSupport
import Foundation
import Testing

struct ClaudeCodeAdapterTests {
    @Test(
        "claude-basic discovers rules, @imports, path-scoped rules, MCP approvals, skills, agents, commands, hooks, and matches goldens"
    )
    func claudeBasicInventoryAndResolution() async throws {
        let fixture = try FixtureHome(scenario: "claude-basic")
        let env = fixture.makeEnvironment()
        let repoFolder = fixture.url.appendingPathComponent("repos/webapp", isDirectory: true)
        let adapter = ClaudeCodeAdapter()

        let artifacts = try await adapter.discover(in: env, folder: repoFolder)
        let resolution = adapter.resolve(artifacts, folder: repoFolder, env: env)

        // Secret redaction check: no synthetic secret value may survive anywhere in encoded inventory JSON.
        let encodedInventory = try GoldenFile.encodeCanonicalJSON(artifacts, homeURL: fixture.url)
        #expect(!encodedInventory.contains("TEST_SYNTHETIC_API_KEY_PLACEHOLDER"))
        #expect(!encodedInventory.contains("TEST_SYNTHETIC_TOKEN_PLACEHOLDER"))
        #expect(!encodedInventory.contains("TEST_SYNTHETIC_DB_PASS_PLACEHOLDER"))
        #expect(encodedInventory.contains("«redacted»"))

        // @import expansion discovered shared-guidelines.md
        let userMemory = try #require(
            artifacts.first { $0.kind == .rules && $0.scope == .user && $0.name == "CLAUDE.md" }
        )
        if case .rules(let doc) = userMemory.payload {
            #expect(doc.imports == ["~/.claude/shared-guidelines.md"])
        } else {
            Issue.record("Expected RulesDoc payload on user CLAUDE.md")
        }
        #expect(artifacts.contains { $0.kind == .rules && $0.name == "shared-guidelines.md" })

        // .claude/rules conditional paths: frontmatter vs unconditional
        let swiftStyleRule = try #require(
            artifacts.first { $0.kind == .rules && $0.name.hasSuffix("swift-style.md") }
        )
        #expect(swiftStyleRule.loadMode == .conditional(globs: ["Sources/**/*.swift", "Tests/**/*.swift"]))

        let generalRule = try #require(
            artifacts.first { $0.kind == .rules && $0.name.hasSuffix("general.md") }
        )
        #expect(generalRule.loadMode == .always)

        // Skill, subagent, command, hook metadata
        let skill = try #require(artifacts.first { $0.kind == .skill && $0.name == "commit-helper" })
        if case .skill(let skillDoc) = skill.payload {
            #expect(skillDoc.supportingFiles == ["scripts/format-msg.sh"])
        } else {
            Issue.record("Expected SkillDoc payload")
        }

        let subagent = try #require(artifacts.first { $0.kind == .subagent && $0.name == "code-reviewer" })
        if case .subagent(let subDoc) = subagent.payload {
            #expect(subDoc.tools == ["Read", "Grep", "Glob"])
            #expect(subDoc.model == "sonnet")
        } else {
            Issue.record("Expected SubagentDoc payload")
        }

        let command = try #require(artifacts.first { $0.kind == .command && $0.name == "standup" })
        if case .command(let cmdDoc) = command.payload {
            #expect(cmdDoc.argumentHint == "[days]")
        } else {
            Issue.record("Expected CommandDoc payload")
        }

        let hook = try #require(artifacts.first { $0.kind == .hook })
        if case .hook(let hookConfig) = hook.payload {
            #expect(hookConfig.event == "PreToolUse")
            #expect(hookConfig.matcher == "Bash")
            #expect(hookConfig.timeoutSeconds == 15)
        } else {
            Issue.record("Expected HookConfig payload")
        }

        // .mcp.json approval: postgres approved in settings.local.json; unapproved-analytics pending approval
        let byID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.id, $0) })
        let resolvedPostgres = try #require(
            resolution.ordered.first { byID[$0.artifactID]?.name == "postgres" }
        )
        #expect(resolvedPostgres.effectiveLoadMode == .always)
        #expect(resolvedPostgres.reason.contains("settings.local.json"))

        let resolvedUnapproved = try #require(
            resolution.ordered.first { byID[$0.artifactID]?.name == "unapproved-analytics" }
        )
        #expect(resolvedUnapproved.effectiveLoadMode == .never)
        #expect(
            resolution.warnings.contains { $0.code == "mcp.unapproved" && $0.message.contains("unapproved-analytics") })

        // Child packages/ui/CLAUDE.md is conditional at repo root, but always when resolved from packages/ui
        let childRule = try #require(
            artifacts.first { $0.kind == .rules && $0.location.path.hasSuffix("packages/ui/CLAUDE.md") }
        )
        let childAtRoot = try #require(resolution.ordered.first { $0.artifactID == childRule.id })
        #expect(childAtRoot.effectiveLoadMode == .conditional(globs: ["packages/ui/**"]))

        let uiSubfolder = repoFolder.appendingPathComponent("packages/ui", isDirectory: true)
        let uiResolution = adapter.resolve(artifacts, folder: uiSubfolder, env: env)
        let childInUI = try #require(uiResolution.ordered.first { $0.artifactID == childRule.id })
        #expect(childInUI.effectiveLoadMode == .always)

        // Log discovery
        let logs = try adapter.logSources(in: env)
        #expect(logs.count == 1)

        try GoldenFile.assertMatches(
            artifacts,
            goldenURL: Self.goldenURL("claude-basic-inventory.json"),
            homeURL: fixture.url
        )
        try GoldenFile.assertMatches(
            resolution,
            goldenURL: Self.goldenURL("claude-basic-resolution.json"),
            homeURL: fixture.url
        )
    }

    @Test(
        "claude-plugins discovers active plugin version, skips stale version, respects enabledPlugins, shadows plugin skills, and matches goldens"
    )
    func claudePluginsInventoryAndResolution() async throws {
        let fixture = try FixtureHome(scenario: "claude-plugins")
        let env = fixture.makeEnvironment()
        let repoFolder = fixture.url.appendingPathComponent("repos/service", isDirectory: true)
        let adapter = ClaudeCodeAdapter()

        let artifacts = try await adapter.discover(in: env, folder: repoFolder)
        let resolution = adapter.resolve(artifacts, folder: repoFolder, env: env)

        // Active plugin 1.2.0 discovered, stale 1.1.0 skipped
        let plugins = artifacts.filter { $0.kind == .plugin }
        #expect(plugins.count == 2)
        #expect(!artifacts.contains { $0.location.path.contains("/1.1.0/") })

        let teamToolkit = try #require(plugins.first { $0.name == "team-toolkit" })
        #expect(teamToolkit.enabled)
        if case .plugin(let manifest) = teamToolkit.payload {
            #expect(manifest.version == "1.2.0")
            #expect(manifest.skills == ["pr-audit", "release-notes"])
            #expect(manifest.agents == ["security-auditor"])
            #expect(manifest.commands == ["changelog"])
            #expect(manifest.mcpServers == ["acme-tracker"])
        } else {
            Issue.record("Expected PluginManifest payload")
        }

        // Disabled legacy-helper plugin is disabled
        let legacyHelper = try #require(plugins.first { $0.name == "legacy-helper" })
        #expect(!legacyHelper.enabled)
        let oldSkill = try #require(artifacts.first { $0.kind == .skill && $0.name == "old-skill" })
        #expect(!oldSkill.enabled)

        // Project skill release-notes shadows team-toolkit plugin skill release-notes
        let byID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.id, $0) })
        let releaseNotesShadows = resolution.shadowed.filter {
            byID[$0.shadowedArtifactID]?.name == "release-notes"
        }
        #expect(releaseNotesShadows.count == 1)
        let shadow = try #require(releaseNotesShadows.first)
        #expect(byID[shadow.winningArtifactID]?.scope == .project)
        #expect(shadow.reason.contains("release-notes"))

        try GoldenFile.assertMatches(
            artifacts,
            goldenURL: Self.goldenURL("claude-plugins-inventory.json"),
            homeURL: fixture.url
        )
        try GoldenFile.assertMatches(
            resolution,
            goldenURL: Self.goldenURL("claude-plugins-resolution.json"),
            homeURL: fixture.url
        )
    }

    @Test(
        "claude-precedence enforces managed > projectLocal > project > user overrides, untrusted .mcp.json protection, and matches goldens"
    )
    func claudePrecedenceInventoryAndResolution() async throws {
        let fixture = try FixtureHome(scenario: "claude-precedence")
        let env = fixture.makeEnvironment()
        let repoFolder = fixture.url.appendingPathComponent("repos/payments", isDirectory: true)
        let adapter = ClaudeCodeAdapter()

        let artifacts = try await adapter.discover(in: env, folder: repoFolder)
        let resolution = adapter.resolve(artifacts, folder: repoFolder, env: env)
        let byID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.id, $0) })

        // 1. Managed MCP corp-gateway shadows user corp-gateway
        let corpGatewayShadows = resolution.shadowed.filter {
            byID[$0.shadowedArtifactID]?.name == "corp-gateway"
        }
        #expect(corpGatewayShadows.count == 1)
        let corpGatewayShadow = try #require(corpGatewayShadows.first)
        #expect(byID[corpGatewayShadow.winningArtifactID]?.scope == .managed)

        // 2. Project-local github MCP shadows both project .mcp.json and user ~/.claude.json
        let githubShadows = resolution.shadowed.filter {
            byID[$0.shadowedArtifactID]?.name == "github"
        }
        #expect(githubShadows.count == 2)
        for record in githubShadows {
            #expect(byID[record.winningArtifactID]?.scope == .projectLocal)
            #expect(!record.reason.isEmpty)
        }

        // 3. Project .mcp.json approval & enterprise deny policy
        let stripeResolved = try #require(
            resolution.ordered.first { byID[$0.artifactID]?.name == "stripe-sandbox" }
        )
        #expect(stripeResolved.effectiveLoadMode == .always)

        let disabledLocalResolved = try #require(
            resolution.ordered.first { byID[$0.artifactID]?.name == "disabled-in-local" }
        )
        #expect(disabledLocalResolved.effectiveLoadMode == .never)
        #expect(disabledLocalResolved.reason.contains("disabledMcpjsonServers"))

        // Untrusted shared .claude/settings.json enableAllProjectMcpServers:true MUST NOT self-approve!
        let selfApprovedAttempt = try #require(
            resolution.ordered.first { byID[$0.artifactID]?.name == "self-approved-attempt" }
        )
        #expect(selfApprovedAttempt.effectiveLoadMode == .never)
        #expect(
            resolution.warnings.contains {
                $0.code == "mcp.unapproved" && $0.message.contains("self-approved-attempt")
            })

        // Enterprise deniedMcpServers blocks user blocked-mcp
        let blockedResolved = try #require(
            resolution.ordered.first { byID[$0.artifactID]?.name == "blocked-mcp" }
        )
        #expect(blockedResolved.effectiveLoadMode == .never)
        #expect(blockedResolved.reason.contains("deniedMcpServers"))

        // 4. Project skill, subagent, and command shadow user counterparts
        for (kind, name) in [(ArtifactKind.skill, "deploy"), (.subagent, "architect"), (.command, "verify")] {
            let matchingShadows = resolution.shadowed.filter {
                byID[$0.shadowedArtifactID]?.kind == kind && byID[$0.shadowedArtifactID]?.name == name
            }
            #expect(matchingShadows.count == 1)
            let firstMatch = try #require(matchingShadows.first)
            #expect(byID[firstMatch.winningArtifactID]?.scope == .project)
        }

        // 5. Rules load in concatenation order: managed -> user -> project -> projectLocal -> child conditional
        let orderedRules = resolution.ordered.compactMap { item -> (Artifact, ResolvedArtifact)? in
            guard let art = byID[item.artifactID], art.kind == .rules else { return nil }
            return (art, item)
        }
        #expect(orderedRules.map(\.0.scope) == [.managed, .user, .project, .projectLocal, .directory])
        #expect(orderedRules.last?.1.effectiveLoadMode == .conditional(globs: ["services/ledger/**"]))

        // Resolving directly inside services/ledger promotes services/ledger/CLAUDE.md to .always
        let ledgerFolder = repoFolder.appendingPathComponent("services/ledger", isDirectory: true)
        let ledgerResolution = adapter.resolve(artifacts, folder: ledgerFolder, env: env)
        let ledgerRule = try #require(orderedRules.last?.0)
        let ledgerResolved = try #require(ledgerResolution.ordered.first { $0.artifactID == ledgerRule.id })
        #expect(ledgerResolved.effectiveLoadMode == .always)

        try GoldenFile.assertMatches(
            artifacts,
            goldenURL: Self.goldenURL("claude-precedence-inventory.json"),
            homeURL: fixture.url
        )
        try GoldenFile.assertMatches(
            resolution,
            goldenURL: Self.goldenURL("claude-precedence-resolution.json"),
            homeURL: fixture.url
        )
    }

    private static func goldenURL(_ filename: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("__golden__", isDirectory: true)
            .appendingPathComponent(filename)
    }
}
