import BentoAdapters
import BentoCore
import BentoFixes
import BentoHygiene
import BentoParsing
import BentoScanner
import BentoStore
import BentoTestSupport
import CryptoKit
import Foundation
import Testing

struct BentoFixesTests {
    private static func defaultFixSupports() -> [AgentID: FixSupport] {
        var map: [AgentID: FixSupport] = [:]
        for adapter in AgentAdapters.all {
            map[type(of: adapter).id] = adapter.fixSupport()
        }
        return map
    }

    private struct Harness {
        var homeURL: URL
        var supportURL: URL
        var trashURL: URL
        var store: BentoStore
        var env: AgentEnvironment
        var workspace: Workspace
        var engine: FixEngine
        var cleanupRoot: URL

        func cleanup() {
            try? store.close()
            try? FileManager.default.removeItem(at: cleanupRoot)
        }
    }

    private static func makeHarness(fromScenario scenario: String? = nil) throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-fixes-\(UUID().uuidString)", isDirectory: true)
        let homeURL = root.appendingPathComponent("home", isDirectory: true)
        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        let trashURL = root.appendingPathComponent("trash", isDirectory: true)

        try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)

        if let scenario {
            let fixture = try FixtureHome(scenario: scenario)
            try FileManager.default.copyItem(at: fixture.url, to: homeURL)
        } else {
            try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        }

        let dbURL = supportURL.appendingPathComponent("bento.sqlite")
        let store = try BentoStore(databaseURL: dbURL)
        let fixedDate = Date(timeIntervalSince1970: 1_761_900_000)
        let env = AgentEnvironment(
            home: homeURL,
            env: ["BENTO_SYSTEM_ROOT": homeURL.path],
            fileSystem: LocalReadOnlyFileSystem(),
            now: { fixedDate }
        )
        let workspace = Workspace(environment: env, store: store)
        let engine = FixEngine(
            homeURL: homeURL,
            supportDirectory: supportURL,
            store: store,
            fileSystem: env.fileSystem,
            trashHandler: HermeticTrashHandler(trashDirectory: trashURL),
            now: { fixedDate }
        )

        return Harness(
            homeURL: homeURL.standardizedFileURL,
            supportURL: supportURL.standardizedFileURL,
            trashURL: trashURL.standardizedFileURL,
            store: store,
            env: env,
            workspace: workspace,
            engine: engine,
            cleanupRoot: root
        )
    }

    /// Computes a full snapshot hash of every regular file, directory, symlink target, and POSIX mode under `root`.
    private static func fullTreeFingerprint(at root: URL) throws -> String {
        let fm = FileManager.default
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        var entries: [String] = []

        func walk(currentFullPath: String, currentRelPrefix: String) throws {
            let names = try fm.contentsOfDirectory(atPath: currentFullPath).sorted()
            for name in names {
                let childRel = currentRelPrefix.isEmpty ? name : "\(currentRelPrefix)/\(name)"
                let childFull = (currentFullPath as NSString).appendingPathComponent(name)
                let attrs = try fm.attributesOfItem(atPath: childFull)
                let fileType = attrs[.type] as? FileAttributeType
                entries.append(childRel)
                // Do not traverse inside symlinks so symlinked directories record only the symlink itself.
                if fileType == .typeDirectory {
                    try walk(currentFullPath: childFull, currentRelPrefix: childRel)
                }
            }
        }

        try walk(currentFullPath: rootPath, currentRelPrefix: "")
        entries.sort()
        #expect(!entries.isEmpty)

        var hasher = SHA256()
        for rel in entries {
            let fullPath = (rootPath as NSString).appendingPathComponent(rel)
            let attrs = try fm.attributesOfItem(atPath: fullPath)
            let fileType = attrs[.type] as? FileAttributeType
            let mode = ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777

            hasher.update(data: Data("entry:/\(rel)|mode:\(String(mode, radix: 8))|".utf8))
            if fileType == .typeSymbolicLink {
                let dest = try fm.destinationOfSymbolicLink(atPath: fullPath)
                hasher.update(data: Data("symlink:\(dest)\n".utf8))
            } else if fileType == .typeDirectory {
                hasher.update(data: Data("dir\n".utf8))
            } else if fileType == .typeRegular {
                let bytes = try Data(contentsOf: URL(fileURLWithPath: fullPath))
                hasher.update(data: Data("file:\(bytes.count):".utf8))
                hasher.update(data: bytes)
                hasher.update(data: Data("\n".utf8))
            }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @Test("Format-preserving JSONSpanEditor preserves // and /* */ comments, trailing commas, and indentation")
    func jsonSpanEditorPreservesCommentsAndFormatting() throws {
        let original = """
            {
              // Header comment that MUST survive
              "permissions": {
                /* Block comment inside permissions */
                "allow": ["Read"],
              },
              "mcpServers": {
                // Active database MCP server
                "postgres": {
                  "command": "npx",
                  "args": ["-y", "@modelcontextprotocol/server-postgres"], // inline args comment
                },
                /* Keep redis untouched */
                "redis": {
                  "command": "redis-mcp"
                }
              }
            }
            """

        // 1. Set nested property inside postgres without disturbing comments
        let withDisabled = try JSONSpanEditor.setProperty(
            in: original,
            keyPath: ["mcpServers", "postgres", "enabled"],
            valueLiteral: "false"
        )
        #expect(withDisabled.contains("// Header comment that MUST survive"))
        #expect(withDisabled.contains("/* Block comment inside permissions */"))
        #expect(withDisabled.contains("// Active database MCP server"))
        #expect(withDisabled.contains("// inline args comment"))
        #expect(withDisabled.contains("/* Keep redis untouched */"))

        let parsedDisabled = try JSONCParser.parseObject(withDisabled, redactSecrets: false)
        if case .object(let servers) = parsedDisabled["mcpServers"],
            case .object(let pg) = servers["postgres"]
        {
            #expect(pg["enabled"] == .bool(false))
        } else {
            Issue.record("Expected mcpServers.postgres.enabled == false")
        }

        // 2. Remove postgres property cleanly while capturing raw value and preserving redis + comments
        let (withoutPostgres, removedRaw) = try JSONSpanEditor.removeObjectProperty(
            in: original,
            keyPath: ["mcpServers", "postgres"]
        )
        let captured = try #require(removedRaw)
        #expect(captured.contains("// inline args comment"))
        #expect(withoutPostgres.contains("// Header comment that MUST survive"))
        #expect(withoutPostgres.contains("/* Keep redis untouched */"))
        let parsedRemoved = try JSONCParser.parseObject(withoutPostgres, redactSecrets: false)
        if case .object(let servers) = parsedRemoved["mcpServers"] {
            #expect(servers["postgres"] == nil)
            #expect(servers["redis"] != nil)
        } else {
            Issue.record("Expected mcpServers object after removal")
        }

        // 3. Upsert & remove string array elements
        let withArray = try JSONSpanEditor.upsertStringArrayElement(
            in: original,
            keyPath: ["disabledMcpjsonServers"],
            element: "github"
        )
        #expect(withArray.contains("// Header comment that MUST survive"))
        let withSecond = try JSONSpanEditor.upsertStringArrayElement(
            in: withArray,
            keyPath: ["disabledMcpjsonServers"],
            element: "linear"
        )
        let afterRemoveOne = try JSONSpanEditor.removeStringArrayElement(
            in: withSecond,
            keyPath: ["disabledMcpjsonServers"],
            element: "github"
        )
        let parsedArray = try JSONCParser.parseObject(afterRemoveOne, redactSecrets: false)
        #expect(parsedArray["disabledMcpjsonServers"] == .array([.string("linear")]))
    }

    @Test("Format-preserving TOMLLineEditor preserves # comments, inline comments, and unrelated sections")
    func tomlLineEditorPreservesCommentsAndFormatting() throws {
        let original = """
            # Top-level Codex config comment
            model = "gpt-5-codex" # default coding model

            [mcp_servers.github]
            # GitHub stdio server comment
            command = "npx"
            args = ["-y", "@modelcontextprotocol/server-github"] # keep inline comment

            [mcp_servers.sqlite]
            command = "uvx"
            enabled = true # inline boolean comment
            """

        // 1. Insert enabled = false into [mcp_servers.github] where enabled did not exist
        let disabledGithub = try TOMLLineEditor.setBooleanInSection(
            in: original,
            sectionPath: ["mcp_servers", "github"],
            key: "enabled",
            value: false
        )
        #expect(disabledGithub.contains("# Top-level Codex config comment"))
        #expect(disabledGithub.contains("# default coding model"))
        #expect(disabledGithub.contains("# GitHub stdio server comment"))
        #expect(disabledGithub.contains("# keep inline comment"))
        #expect(disabledGithub.contains("# inline boolean comment"))

        let parsed1 = try TOMLParser.parseObject(disabledGithub, redactSecrets: false)
        if case .object(let servers) = parsed1["mcp_servers"],
            case .object(let gh) = servers["github"],
            case .object(let sq) = servers["sqlite"]
        {
            #expect(gh["enabled"] == .bool(false))
            #expect(sq["enabled"] == .bool(true))
        } else {
            Issue.record("Expected valid TOML mcp_servers after inserting enabled = false")
        }

        // 2. Flip existing enabled = true -> false in [mcp_servers.sqlite] while keeping inline comment
        let disabledBoth = try TOMLLineEditor.setBooleanInSection(
            in: disabledGithub,
            sectionPath: ["mcp_servers", "sqlite"],
            key: "enabled",
            value: false
        )
        #expect(disabledBoth.contains("# inline boolean comment"))
        let parsed2 = try TOMLParser.parseObject(disabledBoth, redactSecrets: false)
        if case .object(let servers) = parsed2["mcp_servers"],
            case .object(let sq) = servers["sqlite"]
        {
            #expect(sq["enabled"] == .bool(false))
        } else {
            Issue.record("Expected sqlite.enabled == false")
        }
    }

    @Test("Claude Code round-trips all 7 fix kinds apply->undo byte-identically and preserves JSONC comments")
    func claudeCodeAllFixKindsRoundTripByteIdentically() async throws {
        let h = try Self.makeHarness()
        defer { h.cleanup() }

        let claudeDir = h.homeURL.appendingPathComponent(".claude", isDirectory: true)
        let repoURL = h.homeURL.appendingPathComponent("repos/app", isDirectory: true)
        let repoClaudeDir = repoURL.appendingPathComponent(".claude", isDirectory: true)
        let userSkillDir = claudeDir.appendingPathComponent("skills/review-helper", isDirectory: true)
        let repoSkillA = repoClaudeDir.appendingPathComponent("skills/sql-helper", isDirectory: true)
        let repoSkillB = repoURL.appendingPathComponent(".agents/skills/sql-helper", isDirectory: true)

        try FileManager.default.createDirectory(at: userSkillDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoSkillA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoSkillB, withIntermediateDirectories: true)

        // User ~/.claude.json with JSONC comments and a secret env var
        let userClaudeJSON = """
            {
              // Personal Claude state comment
              "mcpServers": {
                // Global linear server
                "linear": {
                  "command": "npx",
                  "args": ["-y", "linear-mcp"],
                  "env": {
                    "LINEAR_API_KEY": "lin_secret_live_token_123"
                  }
                }
              }
            }
            """
        let userClaudeJSONURL = h.homeURL.appendingPathComponent(".claude.json")
        try Data(userClaudeJSON.utf8).write(to: userClaudeJSONURL)

        // Project .mcp.json + .claude/settings.local.json with JSONC comments
        let projectMCP = """
            {
              "mcpServers": {
                "postgres": {
                  "command": "npx",
                  "args": ["-y", "pg-mcp"]
                }
              }
            }
            """
        try Data(projectMCP.utf8).write(to: repoURL.appendingPathComponent(".mcp.json"))

        let settingsLocal = """
            {
              // Keep local approval comment
              "enableAllProjectMcpServers": true
            }
            """
        let settingsLocalURL = repoClaudeDir.appendingPathComponent("settings.local.json")
        try Data(settingsLocal.utf8).write(to: settingsLocalURL)

        // AGENTS.md and CLAUDE.md with 75% duplicate rules + 1 Claude-only line
        let agentsMD = """
            # Shared Rules

            - Validate incoming HTTP payloads at the controller boundary.
            - Keep database transactions short and deterministic.
            - Run all unit tests before opening a pull request.
            """
        let claudeMD = """
            # Claude Rules

            - Validate incoming HTTP payloads at the controller boundary.
            - Keep database transactions short and deterministic.
            - Run all unit tests before opening a pull request.
            - Prefer concise plans before multi-file refactors.
            """
        try Data(agentsMD.utf8).write(to: repoURL.appendingPathComponent("AGENTS.md"))
        let claudeMDURL = repoURL.appendingPathComponent("CLAUDE.md")
        try Data(claudeMD.utf8).write(to: claudeMDURL)

        // Skills + standalone command for trashArtifact
        let reviewSkill = "---\nname: review-helper\ndescription: Review diffs.\n---\n# Review\n"
        try Data(reviewSkill.utf8).write(to: userSkillDir.appendingPathComponent("SKILL.md"))

        let identicalSQLSkill = "---\nname: sql-helper\ndescription: Inspect SQL.\n---\n# SQL\n"
        try Data(identicalSQLSkill.utf8).write(to: repoSkillA.appendingPathComponent("SKILL.md"))
        try Data(identicalSQLSkill.utf8).write(to: repoSkillB.appendingPathComponent("SKILL.md"))

        let commandsDir = repoClaudeDir.appendingPathComponent("commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commandsDir, withIntermediateDirectories: true)
        let obsoleteCmdURL = commandsDir.appendingPathComponent("obsolete.md")
        try Data("Summarize legacy logs.\n".utf8).write(to: obsoleteCmdURL)

        let workspace = Workspace(
            environment: h.env,
            store: h.store,
            repoDiscoveryOptions: RepoDiscoveryOptions(manualPaths: [repoURL])
        )
        let supports = Self.defaultFixSupports()

        // 1. Project .mcp.json disableMCPServer -> undo byte-identical (plus enableMCPServer check)
        let baseline1 = try Self.fullTreeFingerprint(at: h.homeURL)
        let snap1 = try await workspace.scanFull()
        let pgArtifact = try #require(
            snap1.artifacts.first { $0.agent == .claudeCode && $0.kind == .mcpServer && $0.name == "postgres" }
        )
        let planDisablePG = try h.engine.plan(
            FixRequest(kind: .disableMCPServer, artifact: pgArtifact),
            snapshot: snap1,
            fixSupports: supports
        )
        let diffsPG = h.engine.preview(planDisablePG)
        #expect(!diffsPG.isEmpty)
        let resDisablePG = try await h.engine.apply(planDisablePG, allowChanges: true)
        let editedLocalText = try String(contentsOf: settingsLocalURL, encoding: .utf8)
        #expect(editedLocalText.contains("// Keep local approval comment"))
        let snapAfterDisablePG = try await workspace.scanFull()
        let pgResolved = snapAfterDisablePG.resolution(for: .claudeCode, repoPath: repoURL.path)?
            .ordered.first { $0.artifactID == pgArtifact.id }
        #expect(pgResolved?.effectiveLoadMode == .never)

        // Also test enableMCPServer -> undo
        let pgDisabledArtifact = try #require(
            snapAfterDisablePG.artifacts.first {
                $0.agent == .claudeCode && $0.kind == .mcpServer && $0.name == "postgres"
            }
        )
        let planEnablePG = try h.engine.plan(
            FixRequest(kind: .enableMCPServer, artifact: pgDisabledArtifact),
            snapshot: snapAfterDisablePG,
            fixSupports: supports
        )
        let resEnablePG = try await h.engine.apply(planEnablePG, allowChanges: true)
        let snapAfterEnablePG = try await workspace.scanFull()
        let pgReenabled = snapAfterEnablePG.resolution(for: .claudeCode, repoPath: repoURL.path)?
            .ordered.first { $0.artifactID == pgArtifact.id }
        #expect(pgReenabled?.effectiveLoadMode != .never)
        _ = try await h.engine.undo(fixID: resEnablePG.fixID, allowChanges: true)
        _ = try await h.engine.undo(fixID: resDisablePG.fixID, allowChanges: true)
        #expect(try Self.fullTreeFingerprint(at: h.homeURL) == baseline1)

        // 2. User ~/.claude.json disableMCPServer (stashed outside agent file) -> enableMCPServer; and apply->undo byte-identical
        let snap2 = try await workspace.scanFull()
        let linearArtifact = try #require(
            snap2.artifacts.first { $0.agent == .claudeCode && $0.kind == .mcpServer && $0.name == "linear" }
        )
        let planDisableLinear = try h.engine.plan(
            FixRequest(kind: .disableMCPServer, artifact: linearArtifact),
            snapshot: snap2,
            fixSupports: supports
        )
        let resDisableLinear = try await h.engine.apply(planDisableLinear, allowChanges: true)
        let claudeJSONWhileDisabled = try String(contentsOf: userClaudeJSONURL, encoding: .utf8)
        #expect(claudeJSONWhileDisabled.contains("// Personal Claude state comment"))
        #expect(!claudeJSONWhileDisabled.contains("_bentoDisabled"))
        #expect(!claudeJSONWhileDisabled.contains("\"linear\""))
        _ = try await h.engine.undo(fixID: resDisableLinear.fixID, allowChanges: true)
        #expect(try Self.fullTreeFingerprint(at: h.homeURL) == baseline1)

        // Verify disable -> enableMCPServer restores secret env var from stash, then undo both
        let resDisableLinear2 = try await h.engine.apply(planDisableLinear, allowChanges: true)
        let snapLinearDisabled = try await workspace.scanFull()
        let planEnableLinear = try h.engine.plan(
            FixRequest(kind: .enableMCPServer, agent: .claudeCode, targetName: "linear"),
            snapshot: snapLinearDisabled,
            fixSupports: supports
        )
        let resEnableLinear = try await h.engine.apply(planEnableLinear, allowChanges: true)
        let restoredClaudeJSON = try String(contentsOf: userClaudeJSONURL, encoding: .utf8)
        #expect(restoredClaudeJSON.contains("lin_secret_live_token_123"))
        _ = try await h.engine.undo(fixID: resEnableLinear.fixID, allowChanges: true)
        _ = try await h.engine.undo(fixID: resDisableLinear2.fixID, allowChanges: true)
        #expect(try Self.fullTreeFingerprint(at: h.homeURL) == baseline1)

        // 3. disableSkill & enableSkill -> undo byte-identical
        let snap3 = try await workspace.scanFull()
        let reviewArtifact = try #require(
            snap3.artifacts.first { $0.agent == .claudeCode && $0.kind == .skill && $0.name == "review-helper" }
        )
        let planDisableSkill = try h.engine.plan(
            FixRequest(kind: .disableSkill, artifact: reviewArtifact),
            snapshot: snap3,
            fixSupports: supports
        )
        let resDisableSkill = try await h.engine.apply(planDisableSkill, allowChanges: true)
        #expect(!FileManager.default.fileExists(atPath: userSkillDir.path))
        let snapSkillDisabled = try await workspace.scanFull()
        let planEnableSkill = try h.engine.plan(
            FixRequest(kind: .enableSkill, agent: .claudeCode, targetName: "review-helper"),
            snapshot: snapSkillDisabled,
            fixSupports: supports
        )
        let resEnableSkill = try await h.engine.apply(planEnableSkill, allowChanges: true)
        #expect(FileManager.default.fileExists(atPath: userSkillDir.appendingPathComponent("SKILL.md").path))
        _ = try await h.engine.undo(fixID: resEnableSkill.fixID, allowChanges: true)
        _ = try await h.engine.undo(fixID: resDisableSkill.fixID, allowChanges: true)
        #expect(try Self.fullTreeFingerprint(at: h.homeURL) == baseline1)

        // 4. consolidateSkillsViaSymlink -> undo byte-identical
        let snap4 = try await workspace.scanFull()
        let sqlSkills = snap4.artifacts.filter { $0.kind == .skill && $0.name == "sql-helper" }
        #expect(sqlSkills.count >= 2)
        let planConsolidate = try h.engine.plan(
            FixRequest(kind: .consolidateSkillsViaSymlink, artifacts: sqlSkills),
            snapshot: snap4,
            fixSupports: supports
        )
        let resConsolidate = try await h.engine.apply(planConsolidate, allowChanges: true)
        let canonicalSQL = h.homeURL.appendingPathComponent(".agents/skills/sql-helper")
        #expect(FileManager.default.fileExists(atPath: canonicalSQL.appendingPathComponent("SKILL.md").path))
        let attrsA = try FileManager.default.attributesOfItem(atPath: repoSkillA.path)
        #expect((attrsA[.type] as? FileAttributeType) == .typeSymbolicLink)
        _ = try await h.engine.undo(fixID: resConsolidate.fixID, allowChanges: true)
        #expect(try Self.fullTreeFingerprint(at: h.homeURL) == baseline1)

        // 5. replaceDuplicateRulesWithImport -> undo byte-identical
        let snap5 = try await workspace.scanFull()
        let claudeRule = try #require(
            snap5.artifacts.first {
                $0.agent == .claudeCode && $0.kind == .rules && $0.location.path == claudeMDURL.path
            }
        )
        let planImport = try h.engine.plan(
            FixRequest(
                kind: .replaceDuplicateRulesWithImport,
                artifact: claudeRule,
                targetRulesPath: repoURL.appendingPathComponent("AGENTS.md").path
            ),
            snapshot: snap5,
            fixSupports: supports
        )
        let resImport = try await h.engine.apply(planImport, allowChanges: true)
        let importedClaudeText = try String(contentsOf: claudeMDURL, encoding: .utf8)
        #expect(importedClaudeText.contains("@AGENTS.md"))
        #expect(importedClaudeText.contains("Prefer concise plans before multi-file refactors."))
        #expect(!importedClaudeText.contains("Keep database transactions short and deterministic."))
        _ = try await h.engine.undo(fixID: resImport.fixID, allowChanges: true)
        #expect(try Self.fullTreeFingerprint(at: h.homeURL) == baseline1)

        // 6. trashArtifact (requires confirmation) -> undo byte-identical
        let snap6 = try await workspace.scanFull()
        let cmdArtifact = try #require(
            snap6.artifacts.first { $0.agent == .claudeCode && $0.kind == .command && $0.name == "obsolete" }
        )
        #expect(throws: BentoFixesError.self) {
            _ = try h.engine.plan(
                FixRequest(kind: .trashArtifact, artifact: cmdArtifact, confirmed: false),
                snapshot: snap6,
                fixSupports: supports
            )
        }
        let planTrash = try h.engine.plan(
            FixRequest(kind: .trashArtifact, artifact: cmdArtifact, confirmed: true),
            snapshot: snap6,
            fixSupports: supports
        )
        let resTrash = try await h.engine.apply(planTrash, allowChanges: true)
        #expect(!FileManager.default.fileExists(atPath: obsoleteCmdURL.path))
        let trashedItems = try FileManager.default.contentsOfDirectory(atPath: h.trashURL.path)
        #expect(!trashedItems.isEmpty)
        _ = try await h.engine.undo(fixID: resTrash.fixID, allowChanges: true)
        #expect(try Self.fullTreeFingerprint(at: h.homeURL) == baseline1)
    }

    @Test("Codex, Gemini, and Copilot round-trip all supported fix kinds byte-identically and enforce FixSupport")
    func codexGeminiAndCopilotRoundTripAndEnforceCapabilities() async throws {
        let h = try Self.makeHarness()
        defer { h.cleanup() }

        let codexDir = h.homeURL.appendingPathComponent(".codex", isDirectory: true)
        let geminiDir = h.homeURL.appendingPathComponent(".gemini", isDirectory: true)
        let copilotDir = h.homeURL.appendingPathComponent(".copilot", isDirectory: true)
        let repoURL = h.homeURL.appendingPathComponent("repos/multi", isDirectory: true)
        let codexSkillDir = codexDir.appendingPathComponent("skills/bench", isDirectory: true)
        let geminiSkillDir = geminiDir.appendingPathComponent("skills/bench", isDirectory: true)
        let copilotSkillDir = copilotDir.appendingPathComponent("skills/copilot-only", isDirectory: true)

        for dir in [codexDir, geminiDir, copilotDir, repoURL, codexSkillDir, geminiSkillDir, copilotSkillDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let codexTOML = """
            # Codex main configuration comment
            model = "gpt-5-codex"

            [mcp_servers.fetch]
            # Fetch server comment
            command = "uvx"
            args = ["mcp-server-fetch"]
            """
        let codexTOMLURL = codexDir.appendingPathComponent("config.toml")
        try Data(codexTOML.utf8).write(to: codexTOMLURL)

        let geminiJSON = """
            {
              // Gemini user settings comment
              "mcpServers": {
                "brave": {
                  "command": "npx",
                  "args": ["-y", "brave-mcp"]
                }
              }
            }
            """
        let geminiJSONURL = geminiDir.appendingPathComponent("settings.json")
        try Data(geminiJSON.utf8).write(to: geminiJSONURL)

        let copilotMCP = """
            {
              // Copilot MCP comment
              "mcpServers": {
                "github": {
                  "command": "npx",
                  "args": ["-y", "gh-mcp"]
                }
              }
            }
            """
        let copilotMCPURL = copilotDir.appendingPathComponent("mcp-config.json")
        try Data(copilotMCP.utf8).write(to: copilotMCPURL)

        let skillText = "---\nname: bench\ndescription: Benchmark runner.\n---\n# Bench\n"
        try Data(skillText.utf8).write(to: codexSkillDir.appendingPathComponent("SKILL.md"))
        try Data(skillText.utf8).write(to: geminiSkillDir.appendingPathComponent("SKILL.md"))
        try Data("---\nname: copilot-only\ndescription: Copilot skill.\n---\n".utf8)
            .write(to: copilotSkillDir.appendingPathComponent("SKILL.md"))

        let agentsMD = "# Shared\n\n- Always validate environment schemas at startup.\n- Keep handlers stateless.\n"
        let geminiMD =
            "# Gemini\n\n- Always validate environment schemas at startup.\n- Keep handlers stateless.\n- Use Gemini structured output helpers.\n"
        try Data(agentsMD.utf8).write(to: repoURL.appendingPathComponent("AGENTS.md"))
        let geminiMDURL = repoURL.appendingPathComponent("GEMINI.md")
        try Data(geminiMD.utf8).write(to: geminiMDURL)

        let workspace = Workspace(
            environment: h.env,
            store: h.store,
            repoDiscoveryOptions: RepoDiscoveryOptions(manualPaths: [repoURL])
        )
        let supports = Self.defaultFixSupports()
        let baseline = try Self.fullTreeFingerprint(at: h.homeURL)

        // 1. Codex MCP disable -> enable -> undo both byte-identically (preserving TOML comments)
        let snap1 = try await workspace.scanFull()
        let codexMCP = try #require(
            snap1.artifacts.first { $0.agent == .codex && $0.kind == .mcpServer && $0.name == "fetch" }
        )
        let planCodexDisable = try h.engine.plan(
            FixRequest(kind: .disableMCPServer, artifact: codexMCP),
            snapshot: snap1,
            fixSupports: supports
        )
        let resCodexDisable = try await h.engine.apply(planCodexDisable, allowChanges: true)
        let editedTOML = try String(contentsOf: codexTOMLURL, encoding: .utf8)
        #expect(editedTOML.contains("# Codex main configuration comment"))
        #expect(editedTOML.contains("# Fetch server comment"))
        #expect(editedTOML.contains("enabled = false"))

        let snapCodexDisabled = try await workspace.scanFull()
        let codexMCPDisabled = try #require(
            snapCodexDisabled.artifacts.first { $0.agent == .codex && $0.kind == .mcpServer && $0.name == "fetch" }
        )
        #expect(codexMCPDisabled.enabled == false)
        let planCodexEnable = try h.engine.plan(
            FixRequest(kind: .enableMCPServer, artifact: codexMCPDisabled),
            snapshot: snapCodexDisabled,
            fixSupports: supports
        )
        let resCodexEnable = try await h.engine.apply(planCodexEnable, allowChanges: true)
        _ = try await h.engine.undo(fixID: resCodexEnable.fixID, allowChanges: true)
        _ = try await h.engine.undo(fixID: resCodexDisable.fixID, allowChanges: true)
        #expect(try Self.fullTreeFingerprint(at: h.homeURL) == baseline)

        // Codex refuses replaceDuplicateRulesWithImport
        let codexAgentsRule = try #require(
            snap1.artifacts.first { $0.agent == .codex && $0.kind == .rules }
        )
        #expect(throws: BentoFixesError.self) {
            _ = try h.engine.plan(
                FixRequest(
                    kind: .replaceDuplicateRulesWithImport,
                    artifact: codexAgentsRule,
                    targetRulesPath: repoURL.appendingPathComponent("AGENTS.md").path
                ),
                snapshot: snap1,
                fixSupports: supports
            )
        }

        // 2. Gemini MCP disable -> enable -> undo both, plus GEMINI.md @AGENTS.md import -> undo byte-identically
        let geminiMCP = try #require(
            snap1.artifacts.first { $0.agent == .gemini && $0.kind == .mcpServer && $0.name == "brave" }
        )
        let planGeminiDisable = try h.engine.plan(
            FixRequest(kind: .disableMCPServer, artifact: geminiMCP),
            snapshot: snap1,
            fixSupports: supports
        )
        let resGeminiDisable = try await h.engine.apply(planGeminiDisable, allowChanges: true)
        let editedGeminiJSON = try String(contentsOf: geminiJSONURL, encoding: .utf8)
        #expect(editedGeminiJSON.contains("// Gemini user settings comment"))
        #expect(!editedGeminiJSON.contains("\"brave\""))

        let snapGeminiDisabled = try await workspace.scanFull()
        let planGeminiEnable = try h.engine.plan(
            FixRequest(kind: .enableMCPServer, agent: .gemini, targetName: "brave"),
            snapshot: snapGeminiDisabled,
            fixSupports: supports
        )
        let resGeminiEnable = try await h.engine.apply(planGeminiEnable, allowChanges: true)
        _ = try await h.engine.undo(fixID: resGeminiEnable.fixID, allowChanges: true)
        _ = try await h.engine.undo(fixID: resGeminiDisable.fixID, allowChanges: true)
        #expect(try Self.fullTreeFingerprint(at: h.homeURL) == baseline)

        let geminiRule = try #require(
            snap1.artifacts.first {
                $0.agent == .gemini && $0.kind == .rules && $0.location.path == geminiMDURL.path
            }
        )
        let planGeminiImport = try h.engine.plan(
            FixRequest(
                kind: .replaceDuplicateRulesWithImport,
                artifact: geminiRule,
                targetRulesPath: repoURL.appendingPathComponent("AGENTS.md").path
            ),
            snapshot: snap1,
            fixSupports: supports
        )
        let resGeminiImport = try await h.engine.apply(planGeminiImport, allowChanges: true)
        let updatedGeminiMD = try String(contentsOf: geminiMDURL, encoding: .utf8)
        #expect(updatedGeminiMD.contains("@AGENTS.md"))
        #expect(updatedGeminiMD.contains("Use Gemini structured output helpers."))
        _ = try await h.engine.undo(fixID: resGeminiImport.fixID, allowChanges: true)
        #expect(try Self.fullTreeFingerprint(at: h.homeURL) == baseline)

        // 3. Codex + Gemini skill consolidation -> undo byte-identically
        let benchSkills = snap1.artifacts.filter { $0.kind == .skill && $0.name == "bench" }
        #expect(benchSkills.count == 2)
        let planBenchConsolidate = try h.engine.plan(
            FixRequest(kind: .consolidateSkillsViaSymlink, artifacts: benchSkills),
            snapshot: snap1,
            fixSupports: supports
        )
        let resBenchConsolidate = try await h.engine.apply(planBenchConsolidate, allowChanges: true)
        _ = try await h.engine.undo(fixID: resBenchConsolidate.fixID, allowChanges: true)
        #expect(try Self.fullTreeFingerprint(at: h.homeURL) == baseline)

        // 4. Copilot supports MCP disable/enable ONLY, and refuses skill/rules/trash fixes
        let copilotMCPArtifact = try #require(
            snap1.artifacts.first { $0.agent == .copilot && $0.kind == .mcpServer && $0.name == "github" }
        )
        let planCopilotDisable = try h.engine.plan(
            FixRequest(kind: .disableMCPServer, artifact: copilotMCPArtifact),
            snapshot: snap1,
            fixSupports: supports
        )
        let resCopilotDisable = try await h.engine.apply(planCopilotDisable, allowChanges: true)
        let editedCopilotJSON = try String(contentsOf: copilotMCPURL, encoding: .utf8)
        #expect(editedCopilotJSON.contains("// Copilot MCP comment"))
        let snapCopilotDisabled = try await workspace.scanFull()
        let copilotDisabledArtifact = try #require(
            snapCopilotDisabled.artifacts.first { $0.agent == .copilot && $0.kind == .mcpServer && $0.name == "github" }
        )
        #expect(copilotDisabledArtifact.enabled == false)
        _ = try await h.engine.undo(fixID: resCopilotDisable.fixID, allowChanges: true)
        #expect(try Self.fullTreeFingerprint(at: h.homeURL) == baseline)

        let copilotSkill = try #require(
            snap1.artifacts.first { $0.agent == .copilot && $0.kind == .skill && $0.name == "copilot-only" }
        )
        #expect(throws: BentoFixesError.self) {
            _ = try h.engine.plan(
                FixRequest(kind: .disableSkill, artifact: copilotSkill),
                snapshot: snap1,
                fixSupports: supports
            )
        }
        #expect(throws: BentoFixesError.self) {
            _ = try h.engine.plan(
                FixRequest(kind: .trashArtifact, artifact: copilotSkill, confirmed: true),
                snapshot: snap1,
                fixSupports: supports
            )
        }
    }

    @Test(
        "Safety guards: Allow changes gate, .git ban, non-identical skills refusal, TOCTOU abort, and verify auto-rollback"
    )
    func safetyGuardsToctouAndAutoRollback() async throws {
        let h = try Self.makeHarness(fromScenario: "codex-basic")
        defer { h.cleanup() }

        let supports = Self.defaultFixSupports()
        let snap = try await h.workspace.scanFull()
        let baseline = try Self.fullTreeFingerprint(at: h.homeURL)

        let codexMCP = try #require(
            snap.artifacts.first { $0.agent == .codex && $0.kind == .mcpServer && $0.scope == .user }
        )
        let plan = try h.engine.plan(
            FixRequest(kind: .disableMCPServer, artifact: codexMCP),
            snapshot: snap,
            fixSupports: supports
        )

        // 1. Master "Allow changes" off refuses before writing anything
        await #expect(throws: BentoFixesError.allowChangesDisabled) {
            _ = try await h.engine.apply(plan, allowChanges: false)
        }
        #expect(try Self.fullTreeFingerprint(at: h.homeURL) == baseline)

        // 2. .git/ path ban refuses any plan targeting inside .git/
        let gitPlan = FixPlan(
            id: "forbid-git",
            createdAt: h.env.now(),
            kind: .disableMCPServer,
            agent: .claudeCode,
            summary: "Attempt .git write",
            targetArtifactIDs: [],
            affectedPaths: [h.homeURL.appendingPathComponent("repos/app/.git/config").path],
            affectedRepoPath: nil,
            preconditions: [],
            operations: [
                .writeFile(
                    path: h.homeURL.appendingPathComponent("repos/app/.git/config").path,
                    newBytes: Data("bad".utf8),
                    expectedOldHash: nil
                )
            ],
            requiresConfirmation: false
        )
        await #expect(throws: BentoFixesError.self) {
            _ = try await h.engine.apply(gitPlan, allowChanges: true)
        }

        // 3. Non-identical skills are refused with a diff instead of consolidating
        let skillDir1 = h.homeURL.appendingPathComponent(".claude/skills/mismatch", isDirectory: true)
        let skillDir2 = h.homeURL.appendingPathComponent(".codex/skills/mismatch", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillDir2, withIntermediateDirectories: true)
        try Data("---\nname: mismatch\ndescription: Version A\n---\nBody A\n".utf8)
            .write(to: skillDir1.appendingPathComponent("SKILL.md"))
        try Data("---\nname: mismatch\ndescription: Version B\n---\nBody B\n".utf8)
            .write(to: skillDir2.appendingPathComponent("SKILL.md"))

        let snapMismatch = try await h.workspace.scanFull()
        let mismatchSkills = snapMismatch.artifacts.filter { $0.kind == .skill && $0.name == "mismatch" }
        #expect(mismatchSkills.count == 2)
        do {
            _ = try h.engine.plan(
                FixRequest(kind: .consolidateSkillsViaSymlink, artifacts: mismatchSkills),
                snapshot: snapMismatch,
                fixSupports: supports
            )
            Issue.record("Expected BentoFixesError.nonIdenticalSkills")
        } catch let BentoFixesError.nonIdenticalSkills(_, diff) {
            #expect(diff.contains("-description: Version A"))
            #expect(diff.contains("+description: Version B"))
        }

        // 4. TOCTOU guard aborts if target file changes after planning
        let currentBaseline = try Self.fullTreeFingerprint(at: h.homeURL)
        let configURL = URL(fileURLWithPath: codexMCP.location.path)
        let originalBytes = try Data(contentsOf: configURL)
        try Data((String(decoding: originalBytes, as: UTF8.self) + "\n# external edit\n").utf8).write(to: configURL)

        await #expect(throws: BentoFixesError.self) {
            _ = try await h.engine.apply(plan, allowChanges: true)
        }
        // Restore original bytes before testing auto-rollback
        try originalBytes.write(to: configURL)
        #expect(try Self.fullTreeFingerprint(at: h.homeURL) == currentBaseline)

        // 5. Post-state verifier failure triggers automatic rollback + rolled_back journal status
        await #expect(throws: BentoFixesError.self) {
            _ = try await h.engine.apply(plan, allowChanges: true) { _ in
                false
            }
        }
        #expect(try Self.fullTreeFingerprint(at: h.homeURL) == currentBaseline)
        let journal = try #require(try h.store.fetchFixJournalEntry(id: plan.id))
        #expect(journal.status == .rolledBack)

        // 6. Post-apply modification blocks non-forced undo, while force=true restores backup
        let plan2 = try h.engine.plan(
            FixRequest(kind: .disableMCPServer, artifact: codexMCP),
            snapshot: snapMismatch,
            fixSupports: supports
        )
        let applied = try await h.engine.apply(plan2, allowChanges: true)
        try Data((try String(contentsOf: configURL, encoding: .utf8) + "\n# post-apply manual edit\n").utf8)
            .write(to: configURL)
        await #expect(throws: BentoFixesError.self) {
            _ = try await h.engine.undo(fixID: applied.fixID, allowChanges: true, force: false)
        }
        _ = try await h.engine.undo(fixID: applied.fixID, allowChanges: true, force: true)
        #expect(try Self.fullTreeFingerprint(at: h.homeURL) == currentBaseline)
    }
}
