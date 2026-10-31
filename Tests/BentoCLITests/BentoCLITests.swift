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

    private func runCLI(_ arguments: [String]) throws -> CLIResult {
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
        process.environment = [
            "HOME": homePath,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "BENTO_SYSTEM_ROOT": homePath
        ]

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
        DispatchQueue.global(qos: .userInitiated).async {
            outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            pipeGroup.leave()
        }

        pipeGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            pipeGroup.leave()
        }

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
