import BentoAdapters
import BentoCore
import BentoTestSupport
import Foundation
import Testing

struct WindsurfAdapterTests {
    @Test(
        "windsurf-limits enforces 6,000-char global and 12,000-char workspace caps, trigger frontmatter modes, enterprise rules, workflows, MCP serverUrl, and matches goldens"
    )
    func windsurfLimitsInventoryAndResolution() async throws {
        let fixture = try FixtureHome(scenario: "windsurf-limits")
        let env = fixture.makeEnvironment()
        let repoFolder = fixture.url.appendingPathComponent("repos/cascade-app", isDirectory: true)
        let adapter = WindsurfAdapter()

        #expect(WindsurfPathCatalog.globalRuleMaxCharacters == 6_000)
        #expect(WindsurfPathCatalog.workspaceRuleMaxCharacters == 12_000)

        let artifacts = try await adapter.discover(in: env, folder: repoFolder)
        let resolution = adapter.resolve(artifacts, folder: repoFolder, env: env)

        // Secret redaction check: MCP env/header secret values are stripped while env key names remain
        let encodedInventory = try GoldenFile.encodeCanonicalJSON(artifacts, homeURL: fixture.url)
        #expect(!encodedInventory.contains("TEST_SYNTHETIC_WINDSURF_DB_PASSWORD"))
        #expect(!encodedInventory.contains("TEST_SYNTHETIC_WINDSURF_DOCS_TOKEN"))
        #expect(encodedInventory.contains("POSTGRES_PASSWORD"))

        // Enterprise managed rule
        let enterpriseRule = try #require(
            artifacts.first { $0.kind == .rules && $0.scope == .managed }
        )
        #expect(enterpriseRule.loadMode == .always)

        // Global rules (6,050 chars > 6,000 limit) -> wasTruncated == true + rules.sizeLimitExceeded diagnostic
        let globalRule = try #require(
            artifacts.first { $0.kind == .rules && $0.scope == .user && $0.name == "global_rules.md" }
        )
        if case .rules(let globalDoc) = globalRule.payload {
            #expect(globalDoc.characterCount == 6_050)
            #expect(globalDoc.wasTruncated)
        } else {
            Issue.record("Expected RulesDoc on global_rules.md")
        }
        #expect(globalRule.diagnostics.contains { $0.code == "rules.sizeLimitExceeded" })

        // Workspace rules: under-6k (5,950) & under-12k (11,950) NOT truncated; over-12k (12,050) IS truncated
        let under6k = try #require(
            artifacts.first { $0.kind == .rules && $0.location.path.hasSuffix("under-6k.md") }
        )
        if case .rules(let doc) = under6k.payload {
            #expect(doc.characterCount == 5_950)
            #expect(!doc.wasTruncated)
        } else {
            Issue.record("Expected RulesDoc on under-6k.md")
        }
        #expect(under6k.diagnostics.isEmpty)

        let under12k = try #require(
            artifacts.first { $0.kind == .rules && $0.location.path.hasSuffix("under-12k.md") }
        )
        if case .rules(let doc) = under12k.payload {
            #expect(doc.characterCount == 11_950)
            #expect(!doc.wasTruncated)
        } else {
            Issue.record("Expected RulesDoc on under-12k.md")
        }
        #expect(under12k.diagnostics.isEmpty)

        let over12k = try #require(
            artifacts.first { $0.kind == .rules && $0.location.path.hasSuffix("over-12k.md") }
        )
        if case .rules(let doc) = over12k.payload {
            #expect(doc.characterCount == 12_050)
            #expect(doc.wasTruncated)
        } else {
            Issue.record("Expected RulesDoc on over-12k.md")
        }
        #expect(over12k.diagnostics.contains { $0.code == "rules.sizeLimitExceeded" })

        // Trigger modes: always_on, glob, model_decision, manual
        #expect(under6k.loadMode == .always)

        let globRule = try #require(
            artifacts.first { $0.kind == .rules && $0.location.path.hasSuffix("frontend-glob.md") }
        )
        #expect(globRule.loadMode == .conditional(globs: ["web/src/**/*.tsx", "web/src/**/*.ts"]))

        let modelDecisionRule = try #require(
            artifacts.first { $0.kind == .rules && $0.location.path.hasSuffix("architecture-decision.md") }
        )
        #expect(modelDecisionRule.loadMode == .onInvoke)

        let manualRule = try #require(
            artifacts.first { $0.kind == .rules && $0.location.path.hasSuffix("incident-manual.md") }
        )
        #expect(manualRule.loadMode == .onInvoke)

        // Legacy .windsurfrules, AGENTS.md, nested web/AGENTS.md, .codeiumignore
        #expect(artifacts.contains { $0.kind == .rules && $0.name == ".windsurfrules" && $0.loadMode == .always })
        #expect(artifacts.contains { $0.kind == .ignoreFile && $0.name == ".codeiumignore" })

        let webAgents = try #require(
            artifacts.first { $0.kind == .rules && $0.location.path.hasSuffix("web/AGENTS.md") }
        )
        let webAtRoot = try #require(resolution.ordered.first { $0.artifactID == webAgents.id })
        #expect(webAtRoot.effectiveLoadMode == .conditional(globs: ["web/**"]))

        let webFolder = repoFolder.appendingPathComponent("web", isDirectory: true)
        let webResolution = adapter.resolve(artifacts, folder: webFolder, env: env)
        let webInSubdir = try #require(webResolution.ordered.first { $0.artifactID == webAgents.id })
        #expect(webInSubdir.effectiveLoadMode == .always)

        // MCP serverUrl & disabledTools
        let internalDocs = try #require(artifacts.first { $0.kind == .mcpServer && $0.name == "internal-docs" })
        if case .mcpServer(let cfg) = internalDocs.payload {
            #expect(cfg.transport == .http(url: "https://docs.windsurf.example.test/mcp"))
            #expect(cfg.disabledTools == ["delete_article"])
        } else {
            Issue.record("Expected MCPServerConfig on internal-docs")
        }

        // Workflows: workspace ship-check shadows global ship-check
        let projectWorkflow = try #require(
            artifacts.first { $0.kind == .command && $0.name == "ship-check" && $0.scope == .project }
        )
        let globalWorkflow = try #require(
            artifacts.first { $0.kind == .command && $0.name == "ship-check" && $0.scope == .user }
        )
        #expect(
            resolution.shadowed.contains {
                $0.shadowedArtifactID == globalWorkflow.id && $0.winningArtifactID == projectWorkflow.id
            }
        )

        try GoldenFile.assertMatches(
            artifacts,
            goldenURL: Self.goldenURL("windsurf-limits-inventory.json"),
            homeURL: fixture.url
        )
        try GoldenFile.assertMatches(
            resolution,
            goldenURL: Self.goldenURL("windsurf-limits-resolution.json"),
            homeURL: fixture.url
        )
    }

    @Test("Global rules at exactly 6,000 characters are accepted without truncation warning")
    func globalRuleExactBoundaryIsNotTruncated() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-windsurf-boundary-\(UUID().uuidString)", isDirectory: true)
        let memoriesDir = tempRoot.appendingPathComponent(".codeium/windsurf/memories", isDirectory: true)
        try FileManager.default.createDirectory(at: memoriesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let exact6k = String(repeating: "a", count: 6_000)
        try Data(exact6k.utf8).write(to: memoriesDir.appendingPathComponent("global_rules.md"))

        let env = AgentEnvironment(
            home: tempRoot,
            env: ["BENTO_SYSTEM_ROOT": tempRoot.path],
            fileSystem: LocalReadOnlyFileSystem(),
            now: { FixtureHome.defaultTimestamp }
        )

        let artifacts = try await WindsurfAdapter().discover(in: env, folder: nil)
        let globalRule = try #require(artifacts.first { $0.name == "global_rules.md" })
        if case .rules(let doc) = globalRule.payload {
            #expect(doc.characterCount == 6_000)
            #expect(!doc.wasTruncated)
        } else {
            Issue.record("Expected RulesDoc")
        }
        #expect(globalRule.diagnostics.isEmpty)
    }

    private static func goldenURL(_ filename: String) -> URL {
        FixtureHome.repositoryRoot()
            .appendingPathComponent("Tests/BentoAdaptersTests/__golden__", isDirectory: true)
            .appendingPathComponent(filename)
    }
}
