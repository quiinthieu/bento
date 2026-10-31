import BentoCore
import BentoTestSupport
import Foundation
import Testing

struct BentoCLITests {
    @Test("bentoctx scan, inventory, and resolve --json conform to Docs/cli-schema.md")
    func cliJsonOutputsMatchDocumentedSchema() throws {
        let fixture = try FixtureHome(scenario: "polyglot")
        let repoURL = fixture.url.appendingPathComponent("repos/demo-app").standardizedFileURL

        // 1. scan --home <polyglot> --json
        let scanOut = try runCLI(["scan", "--home", fixture.url.path, "--json"])
        #expect(scanOut.exitCode == 0)
        let scanJSON = try parseJSONObject(scanOut.stdout)
        #expect(scanJSON["schemaVersion"] as? Int == 1)
        #expect(scanJSON["command"] as? String == "scan")
        #expect((scanJSON["snapshotID"] as? String)?.isEmpty == false)
        #expect((scanJSON["generatedAt"] as? String)?.isEmpty == false)
        #expect((scanJSON["createdAt"] as? String)?.isEmpty == false)
        #expect(scanJSON["scannerVersion"] as? String == Product.version)
        #expect(scanJSON["homePath"] as? String == fixture.url.standardizedFileURL.path)
        #expect((scanJSON["homeHash"] as? String)?.count == 64)
        #expect((scanJSON["artifactCount"] as? Int ?? 0) > 0)
        #expect(scanJSON["resolutionCount"] as? Int == 6)

        let detections = try #require(scanJSON["detections"] as? [String: Any])
        #expect(detections.count == 6)
        let repos = try #require(scanJSON["repos"] as? [[String: Any]])
        #expect(repos.count == 1)
        #expect(repos.first?["displayName"] as? String == "demo-app")

        // 2. inventory --home <polyglot> --agent claudeCode --json
        let invOut = try runCLI([
            "inventory",
            "--home", fixture.url.path,
            "--agent", "claudeCode",
            "--json"
        ])
        #expect(invOut.exitCode == 0)
        let invJSON = try parseJSONObject(invOut.stdout)
        #expect(invJSON["schemaVersion"] as? Int == 1)
        #expect(invJSON["command"] as? String == "inventory")
        #expect(invJSON["agentFilter"] as? String == "claudeCode")
        #expect(invJSON["repoFilter"] == nil)
        let invArtifacts = try decodeField([Artifact].self, key: "artifacts", in: invOut.stdout)
        #expect(!invArtifacts.isEmpty)
        #expect(invArtifacts.allSatisfy { $0.agent == .claudeCode })

        // 3. resolve --home <polyglot> --repo <demo-app> --agent claude-code --json
        let resOut = try runCLI([
            "resolve",
            "--home", fixture.url.path,
            "--repo", repoURL.path,
            "--agent", "claude-code",
            "--json"
        ])
        #expect(resOut.exitCode == 0)
        let resJSON = try parseJSONObject(resOut.stdout)
        #expect(resJSON["schemaVersion"] as? Int == 1)
        #expect(resJSON["command"] as? String == "resolve")
        #expect(resJSON["agent"] as? String == "claudeCode")
        #expect(resJSON["repoPath"] as? String == repoURL.path)
        let resolution = try decodeField(Resolution.self, key: "resolution", in: resOut.stdout)
        #expect(resolution.agent == .claudeCode)
        #expect(resolution.folder == repoURL.path)
        #expect(!resolution.ordered.isEmpty)
        let resArtifacts = try decodeField([Artifact].self, key: "artifacts", in: resOut.stdout)
        #expect(!resArtifacts.isEmpty)

        // 4. budget --home <polyglot> --repo <demo-app> --json (all 4 budget-capable agents)
        let budgetAllOut = try runCLI([
            "budget",
            "--home", fixture.url.path,
            "--repo", repoURL.path,
            "--json"
        ])
        #expect(budgetAllOut.exitCode == 0)
        let budgetAllJSON = try parseJSONObject(budgetAllOut.stdout)
        #expect(budgetAllJSON["schemaVersion"] as? Int == 1)
        #expect(budgetAllJSON["command"] as? String == "budget")
        #expect(budgetAllJSON["repoPath"] as? String == repoURL.path)
        #expect(budgetAllJSON["agentFilter"] == nil)
        let allBudgets = try decodeField([Budget].self, key: "budgets", in: budgetAllOut.stdout)
        #expect(allBudgets.map(\.agent) == [.claudeCode, .codex, .gemini, .copilot])
        #expect(allBudgets.allSatisfy { $0.prePromptTokens > 0 })

        // 5. budget --home <polyglot> --repo <demo-app> --agent codex --model o3 --json
        let budgetCodexOut = try runCLI([
            "budget",
            "--home", fixture.url.path,
            "--repo", repoURL.path,
            "--agent", "codex",
            "--model", "o3",
            "--json"
        ])
        #expect(budgetCodexOut.exitCode == 0)
        let budgetCodexJSON = try parseJSONObject(budgetCodexOut.stdout)
        #expect(budgetCodexJSON["agentFilter"] as? String == "codex")
        #expect(budgetCodexJSON["modelOverride"] as? String == "o3")
        let codexBudgets = try decodeField([Budget].self, key: "budgets", in: budgetCodexOut.stdout)
        #expect(codexBudgets.count == 1)
        #expect(codexBudgets.first?.model == "o3")
        #expect(codexBudgets.first?.contextWindow == 200_000)
    }

    @Test("bentoctx shares persistent WAL SQLite store via --db and renders human-readable output")
    func cliSharesSQLiteStoreAndRendersHumanOutput() throws {
        let fixture = try FixtureHome(scenario: "polyglot")
        let repoURL = fixture.url.appendingPathComponent("repos/demo-app").standardizedFileURL
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-cli-db-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("bento.sqlite")

        let scanOut = try runCLI([
            "scan",
            "--home", fixture.url.path,
            "--db", dbURL.path,
            "--json"
        ])
        #expect(scanOut.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: dbURL.path))
        let scanJSON = try parseJSONObject(scanOut.stdout)
        let persistedSnapshotID = try #require(scanJSON["snapshotID"] as? String)

        // Subsequent inventory & resolve with the same --db reuse the persisted snapshot ID.
        let invOut = try runCLI([
            "inventory",
            "--home", fixture.url.path,
            "--db", dbURL.path,
            "--repo", repoURL.path,
            "--json"
        ])
        #expect(invOut.exitCode == 0)
        let invJSON = try parseJSONObject(invOut.stdout)
        #expect(invJSON["snapshotID"] as? String == persistedSnapshotID)
        #expect(invJSON["repoFilter"] as? String == repoURL.path)

        let resOut = try runCLI([
            "resolve",
            "--home", fixture.url.path,
            "--db", dbURL.path,
            "--repo", repoURL.path,
            "--agent", "codex",
            "--json"
        ])
        #expect(resOut.exitCode == 0)
        let resJSON = try parseJSONObject(resOut.stdout)
        #expect(resJSON["snapshotID"] as? String == persistedSnapshotID)

        let budgetOut = try runCLI([
            "budget",
            "--home", fixture.url.path,
            "--db", dbURL.path,
            "--repo", repoURL.path,
            "--agent", "claudeCode",
            "--json"
        ])
        #expect(budgetOut.exitCode == 0)
        let budgetJSON = try parseJSONObject(budgetOut.stdout)
        #expect(budgetJSON["snapshotID"] as? String == persistedSnapshotID)

        // Human-readable output (no --json) succeeds cleanly.
        let humanScan = try runCLI(["scan", "--home", fixture.url.path])
        #expect(humanScan.exitCode == 0)
        #expect(humanScan.stdoutString.contains("demo-app"))

        let humanBudget = try runCLI([
            "budget",
            "--home", fixture.url.path,
            "--repo", repoURL.path,
            "--agent", "codex"
        ])
        #expect(humanBudget.exitCode == 0)
        #expect(humanBudget.stdoutString.contains("Pre-prompt tokens:"))
        #expect(humanBudget.stdoutString.contains("gpt-5-codex"))
    }

    @Test("bentoctx runs cleanly against a chmod a-w read-only copy of polyglot without writes")
    func cliRunsCleanlyOnReadOnlyHome() throws {
        let fixture = try FixtureHome(scenario: "polyglot")
        let tempCopy = try fixture.copyToTemporaryDirectory()
        defer {
            Self.setWritableRecursively(at: tempCopy, writable: true)
            try? FileManager.default.removeItem(at: tempCopy)
        }
        Self.setWritableRecursively(at: tempCopy, writable: false)

        let repoPath = tempCopy.appendingPathComponent("repos/demo-app").path
        let scanRes = try runCLI(["scan", "--home", tempCopy.path, "--json"])
        #expect(scanRes.exitCode == 0)
        let invRes = try runCLI(["inventory", "--home", tempCopy.path, "--json"])
        #expect(invRes.exitCode == 0)
        let resRes = try runCLI([
            "resolve",
            "--home", tempCopy.path,
            "--repo", repoPath,
            "--agent", "gemini",
            "--json"
        ])
        #expect(resRes.exitCode == 0)
        let budgetRes = try runCLI([
            "budget",
            "--home", tempCopy.path,
            "--repo", repoPath,
            "--json"
        ])
        #expect(budgetRes.exitCode == 0)
    }

    @Test("bentoctx budget --probe-mcp probes only explicitly named servers and caches results in --db")
    func cliBudgetProbeMCPConsentsAndCachesInStore() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-cli-probe-\(UUID().uuidString)", isDirectory: true)
        let fakeHome = tempRoot.appendingPathComponent("home", isDirectory: true)
        let fakeRepo = fakeHome.appendingPathComponent("repos/app", isDirectory: true)
        let codexDir = fakeHome.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeRepo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fakeServerPath = FixtureHome.repositoryRoot()
            .appendingPathComponent("Fixtures/mcp/fake-server/server.py")
            .standardizedFileURL
            .path
        let probedMarker = tempRoot.appendingPathComponent("probed-spawns.log")
        let unprobedMarker = tempRoot.appendingPathComponent("unprobed-spawns.log")
        let dbPath = tempRoot.appendingPathComponent("cli.sqlite").path

        let configTOML = """
            model = "gpt-5-codex"

            [mcp_servers.consented_srv]
            command = "/usr/bin/python3"
            args = ["\(fakeServerPath)", "--mode", "normal", "--tools", "2", "--marker-file", "\(probedMarker.path)"]

            [mcp_servers.unconsented_srv]
            command = "/usr/bin/python3"
            args = ["\(fakeServerPath)", "--mode", "normal", "--tools", "4", "--marker-file", "\(unprobedMarker.path)"]
            """
        try Data(configTOML.utf8).write(to: codexDir.appendingPathComponent("config.toml"))

        // 1. Without --probe-mcp: zero servers spawned, both use unprobed fallback.
        let unprobedRun = try runCLI([
            "budget",
            "--home", fakeHome.path,
            "--repo", fakeRepo.path,
            "--agent", "codex",
            "--db", dbPath,
            "--json"
        ])
        #expect(unprobedRun.exitCode == 0)
        #expect(!FileManager.default.fileExists(atPath: probedMarker.path))
        #expect(!FileManager.default.fileExists(atPath: unprobedMarker.path))

        // 2. With --probe-mcp consented_srv: ONLY consented_srv spawns; unconsented_srv stays unspawned & uses median fallback!
        let probedRun = try runCLI([
            "budget",
            "--home", fakeHome.path,
            "--repo", fakeRepo.path,
            "--agent", "codex",
            "--db", dbPath,
            "--probe-mcp", "consented_srv",
            "--json"
        ])
        #expect(probedRun.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: probedMarker.path))
        #expect(!FileManager.default.fileExists(atPath: unprobedMarker.path))

        let probedBudgets = try decodeField([Budget].self, key: "budgets", in: probedRun.stdout)
        let codexBudget = try #require(probedBudgets.first)
        let consentedItem = try #require(codexBudget.items.first { $0.label == "consented_srv" })
        let unconsentedItem = try #require(codexBudget.items.first { $0.label == "unconsented_srv" })
        #expect(consentedItem.method.hasPrefix("probed (2 tools,"))
        #expect(unconsentedItem.method.contains("median fallback from 1 probed server"))

        // 3. Subsequent run against same --db without --probe-mcp reuses cached probe with zero new spawns.
        let cachedRun = try runCLI([
            "budget",
            "--home", fakeHome.path,
            "--repo", fakeRepo.path,
            "--agent", "codex",
            "--db", dbPath,
            "--json"
        ])
        #expect(cachedRun.exitCode == 0)
        let spawnLines = try String(contentsOf: probedMarker, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        #expect(spawnLines.count == 1)
    }

    @Test("bentoctx ingest and usage subcommands support incremental offsets, --reset, and Docs/cli-schema.md JSON")
    func cliIngestAndUsageSubcommandsSupportIncrementalResetAndJSONSchema() throws {
        let polyglot = try FixtureHome(scenario: "polyglot")
        let tempCopy = try polyglot.copyToTemporaryDirectory()
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-cli-ingest-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempCopy)
            try? FileManager.default.removeItem(at: dbDir)
        }

        let dbPath = dbDir.appendingPathComponent("bento.sqlite").path
        let demoRepoPath = tempCopy.appendingPathComponent("repos/demo-app").standardizedFileURL.path

        // 1. Initial ingest into shared --db
        let ingest1 = try runCLI([
            "ingest",
            "--home", tempCopy.path,
            "--db", dbPath,
            "--json"
        ])
        #expect(ingest1.exitCode == 0)
        let ingestObj1 = try parseJSONObject(ingest1.stdout)
        #expect(ingestObj1["schemaVersion"] as? Int == 1)
        #expect(ingestObj1["command"] as? String == "ingest")
        #expect(ingestObj1["didReset"] as? Bool == false)
        #expect(ingestObj1["filesDiscovered"] as? Int == 4)
        #expect(ingestObj1["filesIngested"] as? Int == 4)
        #expect(ingestObj1["eventsInserted"] as? Int == 13)
        #expect(ingestObj1["sessionsUpdated"] as? Int == 4)

        // 2. Append 1 new function_call line to Codex rollout log and re-ingest -> only 1 new event inserted!
        let codexRollout = tempCopy.appendingPathComponent(
            ".codex/sessions/2026/10/30/rollout-2026-10-30T10-05-00-poly.jsonl"
        )
        let appendedLine =
            "{\"timestamp\":\"2026-10-30T10:05:10Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"call_id\":\"poly_call_2\",\"name\":\"mcp__docs__search\",\"arguments\":\"{}\"}}\n"
        let handle = try FileHandle(forWritingTo: codexRollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appendedLine.utf8))
        try handle.close()

        let ingest2 = try runCLI([
            "ingest",
            "--home", tempCopy.path,
            "--db", dbPath,
            "--json"
        ])
        #expect(ingest2.exitCode == 0)
        let ingestObj2 = try parseJSONObject(ingest2.stdout)
        #expect(ingestObj2["filesIngested"] as? Int == 1)
        #expect(ingestObj2["eventsInserted"] as? Int == 1)

        // 3. Query usage --json filtered by --repo and --days
        let usageRun = try runCLI([
            "usage",
            "--home", tempCopy.path,
            "--db", dbPath,
            "--days", "3650",
            "--repo", demoRepoPath,
            "--json"
        ])
        #expect(usageRun.exitCode == 0)
        let usageObj = try parseJSONObject(usageRun.stdout)
        #expect(usageObj["schemaVersion"] as? Int == 1)
        #expect(usageObj["command"] as? String == "usage")
        #expect(usageObj["days"] as? Int == 3650)
        #expect(usageObj["sessionCount"] as? Int == 4)
        #expect(usageObj["eventCount"] as? Int == 14)

        // Human-readable usage output check
        let humanUsage = try runCLI([
            "usage",
            "--home", tempCopy.path,
            "--db", dbPath,
            "--days", "3650"
        ])
        #expect(humanUsage.exitCode == 0)
        #expect(humanUsage.stdoutString.contains("Sessions: 4"))

        // 4. Ingest --reset clears state and re-ingests all 14 events cleanly from offset 0
        let resetRun = try runCLI([
            "ingest",
            "--home", tempCopy.path,
            "--db", dbPath,
            "--reset",
            "--json"
        ])
        #expect(resetRun.exitCode == 0)
        let resetObj = try parseJSONObject(resetRun.stdout)
        #expect(resetObj["didReset"] as? Bool == true)
        #expect(resetObj["eventsInserted"] as? Int == 14)
    }

    @Test(
        "bentoctx budget --json includes measuredFirstTurnInput and bentoctx usage --json joins artifacts and flags unused items"
    )
    func cliBudgetIncludesMeasuredFirstTurnInputAndUsageReportsUnusedFindings() throws {
        let fixture = try FixtureHome(scenario: "usage-join")
        let appRepoPath = fixture.url.appendingPathComponent("repos/app").standardizedFileURL.path
        let protoRepoPath = fixture.url.appendingPathComponent("repos/new-prototype").standardizedFileURL.path
        let fixedNowEnv = ["BENTO_NOW_ISO8601": "2026-10-31T00:00:00Z"]

        // 1. bentoctx budget --json includes measuredFirstTurnInput (T12 AC)
        let budgetOut = try runCLI(
            [
                "budget",
                "--home", fixture.url.path,
                "--repo", appRepoPath,
                "--agent", "claudeCode",
                "--json"
            ],
            extraEnv: fixedNowEnv
        )
        #expect(budgetOut.exitCode == 0)
        let budgets = try decodeField([Budget].self, key: "budgets", in: budgetOut.stdout)
        let claudeBudget = try #require(budgets.first)
        #expect(claudeBudget.measuredFirstTurnInput == 18_590)

        let rawBudgetObj = try parseJSONObject(budgetOut.stdout)
        let rawBudgetsArray = try #require(rawBudgetObj["budgets"] as? [[String: Any]])
        #expect(rawBudgetsArray.first?["measuredFirstTurnInput"] as? Int == 18_590)

        // 2. bentoctx usage --days 30 --repo <app> --json emits cost*unused artifactUsage and unusedFindings
        let usageOut = try runCLI(
            [
                "usage",
                "--home", fixture.url.path,
                "--repo", appRepoPath,
                "--days", "30",
                "--json"
            ],
            extraEnv: fixedNowEnv
        )
        #expect(usageOut.exitCode == 0)
        let artifactUsage = try decodeField([ArtifactUsageJoin].self, key: "artifactUsage", in: usageOut.stdout)
        #expect(!artifactUsage.isEmpty)
        #expect(artifactUsage.first?.name == "unused-analytics")
        #expect(artifactUsage.first?.costTimesUnusedScore == 7_200)

        let unusedFindings = try decodeField([Finding].self, key: "unusedFindings", in: usageOut.stdout)
        #expect(unusedFindings.count == 3)
        #expect(unusedFindings.allSatisfy { $0.kind == .unused })

        // 3. Low-session repo (< 5 sessions) emits 0 unusedFindings
        let protoUsageOut = try runCLI(
            [
                "usage",
                "--home", fixture.url.path,
                "--repo", protoRepoPath,
                "--days", "30",
                "--json"
            ],
            extraEnv: fixedNowEnv
        )
        #expect(protoUsageOut.exitCode == 0)
        let protoFindings = try decodeField([Finding].self, key: "unusedFindings", in: protoUsageOut.stdout)
        #expect(protoFindings.isEmpty)
    }

    @Test("bentoctx hygiene --json conforms to schema and enforces --fail-on warning|error exit codes")
    func cliHygieneJsonAndFailOnExitCodes() throws {
        // 1. Clean fixture with --fail-on warning exits 0 with 0 findings.
        let cleanFixture = try FixtureHome(scenario: "clean")
        let cleanOut = try runCLI([
            "hygiene",
            "--home", cleanFixture.url.path,
            "--fail-on", "warning",
            "--json"
        ])
        #expect(cleanOut.exitCode == 0)
        let cleanJSON = try parseJSONObject(cleanOut.stdout)
        #expect(cleanJSON["schemaVersion"] as? Int == 1)
        #expect(cleanJSON["command"] as? String == "hygiene")
        #expect(cleanJSON["findingCount"] as? Int == 0)
        let cleanFindings = try decodeField([Finding].self, key: "findings", in: cleanOut.stdout)
        #expect(cleanFindings.isEmpty)

        // 2. Polyglot fixture has 6 warning-severity findings:
        //    --fail-on error -> exit 0; --fail-on warning -> exit 1 (while still printing valid JSON).
        let polyglotFixture = try FixtureHome(scenario: "polyglot")
        let demoRepoURL = polyglotFixture.url.appendingPathComponent("repos/demo-app").standardizedFileURL

        let polyErrorGate = try runCLI([
            "hygiene",
            "--home", polyglotFixture.url.path,
            "--fail-on", "error",
            "--json"
        ])
        #expect(polyErrorGate.exitCode == 0)
        let polyFindings = try decodeField([Finding].self, key: "findings", in: polyErrorGate.stdout)
        #expect(polyFindings.count == 6)

        let polyWarnGate = try runCLI([
            "hygiene",
            "--home", polyglotFixture.url.path,
            "--repo", demoRepoURL.path,
            "--fail-on", "warning",
            "--json"
        ])
        #expect(polyWarnGate.exitCode != 0)
        let polyWarnJSON = try parseJSONObject(polyWarnGate.stdout)
        #expect(polyWarnJSON["command"] as? String == "hygiene")
        #expect(polyWarnJSON["repoFilter"] as? String == demoRepoURL.path)

        // 3. Broken @import triggers an .error finding so --fail-on error exits non-zero.
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-cli-hygiene-err-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }
        let brokenRepo = tempHome.appendingPathComponent("repos/broken", isDirectory: true)
        try FileManager.default.createDirectory(at: brokenRepo, withIntermediateDirectories: true)
        try Data("# Broken\n\n@./missing-import.md\n".utf8)
            .write(to: brokenRepo.appendingPathComponent("CLAUDE.md"))

        let brokenOut = try runCLI([
            "hygiene",
            "--home", tempHome.path,
            "--repo", brokenRepo.path,
            "--fail-on", "error",
            "--json"
        ])
        #expect(brokenOut.exitCode != 0)
        let brokenFindings = try decodeField([Finding].self, key: "findings", in: brokenOut.stdout)
        #expect(brokenFindings.contains { $0.kind == .brokenImport && $0.severity == .error })
    }

    @Test("CLI fix defaults to dry-run, refuses --apply without --yes in non-TTY, and round-trips apply -> undo")
    func cliFixDryRunNonTTYGuardApplyAndUndoRoundTrip() throws {
        let fixture = try FixtureHome(scenario: "codex-basic")
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-cli-fix-\(UUID().uuidString)", isDirectory: true)
        let tempHome = tempRoot.appendingPathComponent("home", isDirectory: true)
        let tempDBDir = tempRoot.appendingPathComponent("db", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: tempDBDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.url, to: tempHome)

        let configURL = tempHome.appendingPathComponent(".codex/config.toml")
        let originalBytes = try Data(contentsOf: configURL)
        let dbPath = tempDBDir.appendingPathComponent("bento.sqlite").path

        // Find an active user MCP server name in codex-basic
        let invOut = try runCLI([
            "inventory",
            "--home", tempHome.path,
            "--agent", "codex",
            "--json"
        ])
        #expect(invOut.exitCode == 0)
        let artifacts = try decodeField([Artifact].self, key: "artifacts", in: invOut.stdout)
        let mcpTarget = try #require(
            artifacts.first { $0.kind == .mcpServer && $0.scope == .user && $0.enabled }
        )

        // 1. Default dry-run produces diff JSON without modifying config.toml
        let dryOut = try runCLI([
            "fix",
            "disableMCPServer",
            mcpTarget.id.rawValue,
            "--home", tempHome.path,
            "--db", dbPath,
            "--json"
        ])
        #expect(dryOut.exitCode == 0)
        let dryJSON = try parseJSONObject(dryOut.stdout)
        #expect(dryJSON["schemaVersion"] as? Int == 1)
        #expect(dryJSON["command"] as? String == "fix")
        #expect(dryJSON["applied"] as? Bool == false)
        #expect(try Data(contentsOf: configURL) == originalBytes)

        // 2. --apply WITHOUT --yes in non-TTY subprocess MUST fail and leave config.toml untouched
        let refusedOut = try runCLI([
            "fix",
            "disableMCPServer",
            mcpTarget.id.rawValue,
            "--home", tempHome.path,
            "--db", dbPath,
            "--apply",
            "--json"
        ])
        #expect(refusedOut.exitCode != 0)
        #expect(try Data(contentsOf: configURL) == originalBytes)

        // 3. --apply --yes applies the fix, records journal ID, and `undo <fixID>` restores byte-for-byte
        let applyOut = try runCLI([
            "fix",
            "disableMCPServer",
            mcpTarget.id.rawValue,
            "--home", tempHome.path,
            "--db", dbPath,
            "--apply",
            "--yes",
            "--json"
        ])
        #expect(applyOut.exitCode == 0, "stderr: \(String(decoding: applyOut.stderr, as: UTF8.self))")
        let applyJSON = try parseJSONObject(applyOut.stdout)
        #expect(applyJSON["applied"] as? Bool == true)
        let fixID = try #require(applyJSON["fixID"] as? String)
        #expect(try Data(contentsOf: configURL) != originalBytes)

        let undoOut = try runCLI([
            "undo",
            fixID,
            "--home", tempHome.path,
            "--db", dbPath,
            "--json"
        ])
        #expect(undoOut.exitCode == 0, "stderr: \(String(decoding: undoOut.stderr, as: UTF8.self))")
        let undoJSON = try parseJSONObject(undoOut.stdout)
        #expect(undoJSON["schemaVersion"] as? Int == 1)
        #expect(undoJSON["command"] as? String == "undo")
        #expect(undoJSON["status"] as? String == "undone")
        #expect(try Data(contentsOf: configURL) == originalBytes)
    }

    // MARK: - Helpers

    private struct CLIResult {
        var exitCode: Int32
        var stdout: Data
        var stderr: Data

        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    private func runCLI(_ arguments: [String], extraEnv: [String: String] = [:]) throws -> CLIResult {
        let binary = try Self.locateBuiltCLIBinary()
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments

        let homePath: String
        if let homeIndex = arguments.firstIndex(of: "--home"), homeIndex + 1 < arguments.count {
            homePath = arguments[homeIndex + 1]
        } else {
            homePath = FileManager.default.temporaryDirectory.path
        }
        var envDict: [String: String] = [
            "HOME": homePath,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "BENTO_SYSTEM_ROOT": homePath
        ]
        for (key, value) in extraEnv {
            envDict[key] = value
        }
        process.environment = envDict

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            exitSemaphore.signal()
        }

        try process.run()
        try? inPipe.fileHandleForWriting.close()

        let outBox = DataBox()
        let errBox = DataBox()
        let pipeGroup = DispatchGroup()

        pipeGroup.enter()
        let outThread = Thread {
            outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            pipeGroup.leave()
        }
        outThread.qualityOfService = .userInitiated
        outThread.start()

        pipeGroup.enter()
        let errThread = Thread {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            pipeGroup.leave()
        }
        errThread.qualityOfService = .userInitiated
        errThread.start()

        let waitResult = exitSemaphore.wait(timeout: .now() + .seconds(15))
        if waitResult == .timedOut {
            process.terminate()
            _ = exitSemaphore.wait(timeout: .now() + .seconds(2))
            Issue.record("CLI subprocess timed out for arguments: \(arguments)")
        }
        _ = pipeGroup.wait(timeout: .now() + .seconds(5))

        return CLIResult(
            exitCode: process.terminationStatus,
            stdout: outBox.data,
            stderr: errBox.data
        )
    }

    private func parseJSONObject(_ data: Data) throws -> [String: Any] {
        let raw = try JSONSerialization.jsonObject(with: data)
        return try #require(raw as? [String: Any])
    }

    private func decodeField<T: Decodable>(_ type: T.Type, key: String, in data: Data) throws -> T {
        let obj = try parseJSONObject(data)
        let fieldObj = try #require(obj[key])
        let fieldData = try JSONSerialization.data(withJSONObject: fieldObj)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: fieldData)
    }

    private static func locateBuiltCLIBinary() throws -> URL {
        let bundleURL = Bundle(for: CLIBundleAnchor.self).bundleURL
        let buildDir = bundleURL.deletingLastPathComponent()
        let siblingBinary = buildDir.appendingPathComponent(Product.cliName)
        if FileManager.default.isExecutableFile(atPath: siblingBinary.path) {
            return siblingBinary
        }

        let debugBinary = FixtureHome.repositoryRoot()
            .appendingPathComponent(".build/debug")
            .appendingPathComponent(Product.cliName)
        if FileManager.default.isExecutableFile(atPath: debugBinary.path) {
            return debugBinary
        }

        throw CocoaError(.fileNoSuchFile)
    }

    private static func setWritableRecursively(at root: URL, writable: Bool) {
        let fm = FileManager.default
        var urls: [URL] = [root.standardizedFileURL]
        if let enumerator = fm.enumerator(at: root.standardizedFileURL, includingPropertiesForKeys: nil) {
            while let next = enumerator.nextObject() as? URL {
                urls.append(next.standardizedFileURL)
            }
        }
        for url in (writable ? urls : urls.reversed()) {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue }
            if (attrs[.type] as? FileAttributeType) == .typeSymbolicLink { continue }
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o755
            let updated = writable ? (perms | 0o200) : (perms & ~0o222)
            try? fm.setAttributes([.posixPermissions: updated], ofItemAtPath: url.path)
        }
    }
}

private final class CLIBundleAnchor {}
