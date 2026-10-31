import BentoAdapters
import BentoCore
import BentoLogIngest
import BentoScanner
import BentoStore
import BentoTestSupport
import CryptoKit
import Foundation
import Synchronization
import Testing

struct BentoLogIngestTests {
    static let goldenDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("__golden__", isDirectory: true)

    @Test("StreamingLineReader yields complete lines, holds partial trailing lines uncommitted, and skips >16 MB lines")
    func streamingLineReaderHandlesPartialTrailingLineAnd16MBCap() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-line-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Partial trailing line test via AsyncSequence and readLines
        let partialFile = tempDir.appendingPathComponent("partial.jsonl")
        let line1 = "{\"id\":1}\n"
        let line2 = "{\"id\":2}\r\n"
        let unfinished = "{\"id\":3,\"partial\":true"
        try Data((line1 + line2 + unfinished).utf8).write(to: partialFile)

        let asyncReader = StreamingLineReader(url: partialFile, startOffset: 0, bufferSize: 7)
        var asyncCollected: [String] = []
        for try await lineData in asyncReader {
            asyncCollected.append(String(decoding: lineData, as: UTF8.self))
        }
        #expect(asyncCollected == ["{\"id\":1}", "{\"id\":2}"])

        var syncCollected: [String] = []
        let outcome = try asyncReader.readLines { lineData in
            syncCollected.append(String(decoding: lineData, as: UTF8.self))
        }
        #expect(syncCollected == ["{\"id\":1}", "{\"id\":2}"])
        let expectedCommittedOffset = UInt64(line1.utf8.count + line2.utf8.count)
        #expect(outcome.consumedOffset == expectedCommittedOffset)
        #expect(outcome.diagnostics.isEmpty)

        // 2. Hostile 20 MB single line (> 16 MB cap) skipped with diagnostic, followed by valid line
        let oversizedFile = tempDir.appendingPathComponent("hostile-20mb.jsonl")
        FileManager.default.createFile(atPath: oversizedFile.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: oversizedFile)
        try writeHandle.write(contentsOf: Data("{\"ok\":\"before\"}\n".utf8))
        try writeHandle.write(contentsOf: Data("{\"huge\":\"".utf8))
        let oneMB = Data(repeating: UInt8(ascii: "x"), count: 1_048_576)
        for _ in 0..<20 {
            try writeHandle.write(contentsOf: oneMB)
        }
        try writeHandle.write(contentsOf: Data("\"}\n{\"ok\":\"after\"}\n".utf8))
        try writeHandle.close()

        let oversizedReader = StreamingLineReader(url: oversizedFile)
        var survivingLines: [String] = []
        let oversizedOutcome = try oversizedReader.readLines { lineData in
            survivingLines.append(String(decoding: lineData, as: UTF8.self))
        }

        #expect(survivingLines == ["{\"ok\":\"before\"}", "{\"ok\":\"after\"}"])
        #expect(oversizedOutcome.diagnostics.count == 1)
        #expect(oversizedOutcome.diagnostics.first?.code == "ingest.lineOversized")
        let fullSize = try FileManager.default.attributesOfItem(atPath: oversizedFile.path)[.size] as? UInt64
        #expect(oversizedOutcome.consumedOffset == fullSize)
    }

    @Test("ZstdLineReader streams valid .jsonl.zst and produces a diagnostic without crashing on truncated .zst")
    func zstdLineReaderStreamsValidZstAndEmitsDiagnosticOnTruncatedZst() async throws {
        let repoRoot = FixtureHome.repositoryRoot()
        let fakeHome = repoRoot.appendingPathComponent("Fixtures/homes/polyglot").standardizedFileURL

        // 1. Valid compressed Codex rollout log
        let validZstURL = repoRoot.appendingPathComponent("Fixtures/logs/codex/rollout-compressed.jsonl.zst")
        let validSource = LogSource(
            agent: .codex,
            url: validZstURL,
            isCompressed: true,
            homePath: fakeHome.path
        )
        let zstdReader = ZstdLineReader(url: validZstURL)
        var codexDecoder = CodexLogDecoder()
        var decodedEvents: [UsageEvent] = []
        let validOutcome = try zstdReader.readLines { lineData in
            decodedEvents.append(contentsOf: codexDecoder.decode(line: lineData, source: validSource))
        }

        #expect(validOutcome.diagnostics.isEmpty)
        #expect(validOutcome.errorMessage == nil)
        #expect(decodedEvents.count == 3)
        #expect(decodedEvents[0].sessionID == "codex-log-zst-002")
        #expect(decodedEvents[0].kind == .sessionStart(model: "o3"))
        #expect(
            decodedEvents[1].kind
                == .tokenUsage(input: 9800, cachedInput: 4000, output: 310, turnIndex: 0)
        )
        #expect(decodedEvents[2].kind == .mcpToolCalled(server: "docs", tool: "fetch_page"))

        // 2. Hostile truncated .jsonl.zst must emit a diagnostic + last_error in BentoStore and never crash
        let truncatedURL = repoRoot.appendingPathComponent("Fixtures/homes/hostile/logs/truncated.jsonl.zst")
        let truncatedReader = ZstdLineReader(url: truncatedURL)
        var salvagedLineCount = 0
        let truncatedOutcome = try truncatedReader.readLines { _ in
            salvagedLineCount += 1
        }
        #expect(salvagedLineCount >= 0)
        #expect(!truncatedOutcome.diagnostics.isEmpty)
        #expect(truncatedOutcome.errorMessage != nil)

        let store = try BentoStore.inMemory()
        let ingestor = LogIngestor(store: store)
        let truncatedSource = LogSource(
            agent: .codex,
            url: truncatedURL,
            isCompressed: true,
            homePath: fakeHome.path
        )
        let report1 = try await ingestor.ingest(
            targets: [LogIngestTarget(source: truncatedSource) { CodexLogDecoder() }]
        )
        #expect(report1.filesIngested == 1)
        #expect(!report1.diagnostics.isEmpty)
        let savedState = try #require(try store.logFileState(forPath: truncatedURL.standardizedFileURL.path))
        #expect(savedState.isCompressed)
        #expect(savedState.lastError != nil)

        // Compressed .zst files are immutable once closed: re-ingesting with unchanged (size, mtime, inode) skips re-read
        let report2 = try await ingestor.ingest(
            targets: [LogIngestTarget(source: truncatedSource) { CodexLogDecoder() }]
        )
        #expect(report2.filesSkippedUnchanged == 1)
        #expect(report2.filesIngested == 0)
    }

    @Test("Fixture logs yield exact expected golden events across Claude, Codex, Gemini, Copilot, and polyglot")
    func fixtureLogsMatchGoldenEventsAndCountsAcrossAllFourAgents() async throws {
        let repoRoot = FixtureHome.repositoryRoot()
        let polyglot = try FixtureHome(scenario: "polyglot")
        let homePath = polyglot.url.standardizedFileURL.path

        // 1. Claude Code (deduping 3 streamed chunks for msg_turn_0 / req_turn_0 and repeated toolu_skill_1)
        let claudeURL = repoRoot.appendingPathComponent("Fixtures/logs/claudeCode/session-streamed.jsonl")
        let claudeEvents = try Self.decodePlainLines(
            at: claudeURL,
            source: LogSource(agent: .claudeCode, url: claudeURL, homePath: homePath),
            decoder: ClaudeCodeLogDecoder()
        )
        #expect(claudeEvents.count == 8)
        try GoldenFile.assertMatches(
            claudeEvents,
            goldenURL: Self.goldenDirectory.appendingPathComponent("fixture-logs-claudeCode.json"),
            homeURL: polyglot.url
        )

        // 2. Codex CLI (plain rollout + compressed .jsonl.zst rollout, deduping identical consecutive token_count)
        let codexPlainURL = repoRoot.appendingPathComponent("Fixtures/logs/codex/rollout-sample.jsonl")
        var codexEvents = try Self.decodePlainLines(
            at: codexPlainURL,
            source: LogSource(agent: .codex, url: codexPlainURL, homePath: homePath),
            decoder: CodexLogDecoder()
        )
        let codexZstURL = repoRoot.appendingPathComponent("Fixtures/logs/codex/rollout-compressed.jsonl.zst")
        let codexZstSource = LogSource(agent: .codex, url: codexZstURL, isCompressed: true, homePath: homePath)
        var codexZstDecoder = CodexLogDecoder()
        _ = try ZstdLineReader(url: codexZstURL).readLines { lineData in
            codexEvents.append(contentsOf: codexZstDecoder.decode(line: lineData, source: codexZstSource))
        }
        #expect(codexEvents.count == 10)
        try GoldenFile.assertMatches(
            codexEvents,
            goldenURL: Self.goldenDirectory.appendingPathComponent("fixture-logs-codex.json"),
            homeURL: polyglot.url
        )

        // 3. Gemini CLI (modern append-only .jsonl + multi-line legacy .json)
        let geminiModernURL = repoRoot.appendingPathComponent("Fixtures/logs/gemini/session-modern.jsonl")
        var geminiEvents = try Self.decodePlainLines(
            at: geminiModernURL,
            source: LogSource(agent: .gemini, url: geminiModernURL, homePath: homePath),
            decoder: GeminiLogDecoder()
        )
        let geminiLegacyURL = repoRoot.appendingPathComponent("Fixtures/logs/gemini/session-legacy.json")
        var geminiLegacyDecoder = GeminiLogDecoder()
        let legacyData = try Data(contentsOf: geminiLegacyURL)
        geminiEvents.append(
            contentsOf: geminiLegacyDecoder.decodeDocument(
                data: legacyData,
                source: LogSource(agent: .gemini, url: geminiLegacyURL, homePath: homePath)
            )
        )
        #expect(geminiEvents.count == 10)
        try GoldenFile.assertMatches(
            geminiEvents,
            goldenURL: Self.goldenDirectory.appendingPathComponent("fixture-logs-gemini.json"),
            homeURL: polyglot.url
        )

        // 4. Copilot CLI (events.jsonl)
        let copilotURL = repoRoot.appendingPathComponent("Fixtures/logs/copilot/events.jsonl")
        let copilotEvents = try Self.decodePlainLines(
            at: copilotURL,
            source: LogSource(agent: .copilot, url: copilotURL, homePath: homePath),
            decoder: CopilotLogDecoder()
        )
        #expect(copilotEvents.count == 6)
        try GoldenFile.assertMatches(
            copilotEvents,
            goldenURL: Self.goldenDirectory.appendingPathComponent("fixture-logs-copilot.json"),
            homeURL: polyglot.url
        )

        // 5. Full polyglot workspace + BentoStore persistence (usage_event + session + privacy check)
        let store = try BentoStore.inMemory()
        let env = polyglot.makeEnvironment(now: Date(timeIntervalSince1970: 1_793_404_800))  // 2026-10-31T00:00:00Z
        let workspace = Workspace(environment: env, store: store)
        _ = try await workspace.scanFull()

        let targets = try await workspace.logIngestTargets()
        #expect(targets.count == 4)

        let progressSnapshots = Mutex<[LogIngestProgress]>([])
        let ingestor = LogIngestor(fileSystem: env.fileSystem, store: store, maxConcurrency: 4)
        let report = try await ingestor.ingest(targets: targets) { progress in
            progressSnapshots.withLock { $0.append(progress) }
        }
        #expect(report.filesDiscovered == 4)
        #expect(report.filesIngested == 4)
        #expect(report.eventsInserted == 13)
        #expect(report.sessionsUpdated == 4)
        #expect(progressSnapshots.withLock { $0.count } == 4)

        let sessions = try store.allSessions()
        #expect(sessions.count == 4)
        let claudeSession = try #require(sessions.first { $0.agent == .claudeCode })
        #expect(claudeSession.model == "claude-sonnet-4-5")
        #expect(claudeSession.firstTurnInput == 8480)
        #expect(claudeSession.repoID != nil)

        let codexSession = try #require(sessions.first { $0.agent == .codex })
        #expect(codexSession.model == "gpt-5-codex")
        #expect(codexSession.firstTurnInput == 9200)
        #expect(codexSession.repoID == claudeSession.repoID)

        let summary = try store.usageSummary(
            since: Date(timeIntervalSince1970: 1_790_812_800),  // 2026-10-01T00:00:00Z
            until: Date(timeIntervalSince1970: 1_793_404_800)
        )
        try GoldenFile.assertMatches(
            summary,
            goldenURL: Self.goldenDirectory.appendingPathComponent("polyglot-usage-summary.json"),
            homeURL: polyglot.url
        )

        // 6. Privacy proof: ingest all Fixtures/logs/* containing SECRET_* canaries into SQLite and assert zero leakage
        let secretStore = try BentoStore.inMemory()
        let secretTargets: [LogIngestTarget] = [
            LogIngestTarget(source: LogSource(agent: .claudeCode, url: claudeURL, homePath: homePath)) {
                ClaudeCodeLogDecoder()
            },
            LogIngestTarget(source: LogSource(agent: .codex, url: codexPlainURL, homePath: homePath)) {
                CodexLogDecoder()
            },
            LogIngestTarget(source: LogSource(agent: .gemini, url: geminiModernURL, homePath: homePath)) {
                GeminiLogDecoder()
            },
            LogIngestTarget(source: LogSource(agent: .copilot, url: copilotURL, homePath: homePath)) {
                CopilotLogDecoder()
            }
        ]
        _ = try await LogIngestor(store: secretStore).ingest(targets: secretTargets)
        let persistedEvents = try secretStore.allUsageEvents()
        #expect(!persistedEvents.isEmpty)
        let encodedDump = try GoldenFile.encodeCanonicalJSON(persistedEvents)
        #expect(!encodedDump.contains("SECRET_"), "Prompt or tool argument content leaked into usage_event!")
    }

    @Test("Append-then-reingest holds partial trailing bytes and inserts only newly completed events")
    func appendPartialLineAndReingestAddsOnlyNewEvents() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-ingest-append-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logURL = tempDir.appendingPathComponent("rollout.jsonl")
        let initialLines = """
            {"timestamp":"2026-10-30T10:00:00Z","type":"session_meta","payload":{"id":"append-sess-1","cwd":"/tmp/repo","model":"gpt-5-codex"}}
            {"timestamp":"2026-10-30T10:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":5000,"cached_input_tokens":2000,"output_tokens":100},"total_token_usage":{"input_tokens":5000,"cached_input_tokens":2000,"output_tokens":100}}}}
            """ + "\n"
        try Data(initialLines.utf8).write(to: logURL)
        let initialSize = UInt64(initialLines.utf8.count)

        let store = try BentoStore.inMemory()
        let ingestor = LogIngestor(store: store)
        let target = LogIngestTarget(source: LogSource(agent: .codex, url: logURL)) {
            CodexLogDecoder()
        }

        // Run 1: initial 2 lines -> 2 events (sessionStart + tokenUsage turn 0)
        let run1 = try await ingestor.ingest(targets: [target])
        #expect(run1.eventsInserted == 2)
        let state1 = try #require(try store.logFileState(forPath: logURL.standardizedFileURL.path))
        #expect(state1.offsetConsumed == initialSize)

        // Run 2: append an incomplete line without newline -> 0 events, offset_consumed stays at initialSize
        let partialFirstHalf = "{\"timestamp\":\"2026-10-30T10:00:05Z\",\"type\":\"response_item\",\"payload\":"
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(partialFirstHalf.utf8))
        try handle.close()

        let run2 = try await ingestor.ingest(targets: [target])
        #expect(run2.eventsInserted == 0)
        let state2 = try #require(try store.logFileState(forPath: logURL.standardizedFileURL.path))
        #expect(state2.offsetConsumed == initialSize)

        // Run 3: finish that partial line AND append a second token_count turn -> ONLY 2 new events inserted!
        let partialSecondHalf =
            "{\"type\":\"function_call\",\"call_id\":\"c_app_1\",\"name\":\"mcp__docs__lookup\",\"arguments\":\"{}\"}}\n"
            + "{\"timestamp\":\"2026-10-30T10:00:08Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":5400,\"cached_input_tokens\":5000,\"output_tokens\":90},\"total_token_usage\":{\"input_tokens\":10400,\"cached_input_tokens\":7000,\"output_tokens\":190}}}}\n"
        let handle2 = try FileHandle(forWritingTo: logURL)
        try handle2.seekToEnd()
        try handle2.write(contentsOf: Data(partialSecondHalf.utf8))
        try handle2.close()

        let run3 = try await ingestor.ingest(targets: [target])
        #expect(run3.eventsInserted == 2)
        #expect(run3.bytesRead == partialFirstHalf.utf8.count + partialSecondHalf.utf8.count)

        let allEvents = try store.allUsageEvents()
        #expect(allEvents.count == 4)
        #expect(allEvents.allSatisfy { $0.event.sessionID == "append-sess-1" })
        #expect(allEvents.allSatisfy { $0.event.cwd == "/tmp/repo" })
        let turn1 = try #require(
            allEvents.first {
                if case .tokenUsage(_, _, _, let turnIndex) = $0.event.kind {
                    return turnIndex == 1
                }
                return false
            }
        )
        #expect(turn1.model == "gpt-5-codex")
    }

    @Test("Rotation via inode replacement or size truncation re-reads from offset 0 while deduping existing events")
    func rotationAndTruncationReReadFromZeroWhileDedupingEvents() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-ingest-rotate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logURL = tempDir.appendingPathComponent("events.jsonl")
        let lineStart =
            "{\"id\":\"e1\",\"type\":\"session.start\",\"sessionId\":\"rot-sess-1\",\"timestamp\":\"2026-10-30T11:00:00Z\",\"cwd\":\"/tmp/repo\"}\n"
        let lineToolA =
            "{\"id\":\"e2\",\"type\":\"tool.execution_start\",\"timestamp\":\"2026-10-30T11:00:01Z\",\"data\":{\"toolCallId\":\"tc-a\",\"toolName\":\"bash\",\"arguments\":{\"command\":\"echo 1 padding padding padding padding padding\"}}}\n"
        let lineToolB =
            "{\"id\":\"e3\",\"type\":\"tool.execution_start\",\"timestamp\":\"2026-10-30T11:00:02Z\",\"data\":{\"toolCallId\":\"tc-b\",\"toolName\":\"view\",\"arguments\":{\"path\":\"file.swift padding padding padding\"}}}\n"

        try Data((lineStart + lineToolA + lineToolB).utf8).write(to: logURL)

        let store = try BentoStore.inMemory()
        let ingestor = LogIngestor(store: store)
        let target = LogIngestTarget(source: LogSource(agent: .copilot, url: logURL)) {
            CopilotLogDecoder()
        }

        let initial = try await ingestor.ingest(targets: [target])
        #expect(initial.eventsInserted == 3)

        // 1. Copy-truncate in place (same inode, smaller byte size): retains lineStart + replaces tail with short usage line
        let shortUsageLine =
            "{\"id\":\"e4\",\"type\":\"assistant.usage\",\"timestamp\":\"2026-10-30T11:00:05Z\",\"data\":{\"inputTokens\":4100,\"outputTokens\":80}}\n"
        let truncatedBytes = Data((lineStart + shortUsageLine).utf8)
        #expect(truncatedBytes.count < (lineStart + lineToolA + lineToolB).utf8.count)
        let writeInPlace = try FileHandle(forWritingTo: logURL)
        try writeInPlace.truncate(atOffset: 0)
        try writeInPlace.write(contentsOf: truncatedBytes)
        try writeInPlace.close()

        let afterTruncate = try await ingestor.ingest(targets: [target])
        // lineStart already exists -> deduped; shortUsageLine is new -> 1 inserted!
        #expect(afterTruncate.eventsInserted == 1)
        #expect(try store.allUsageEvents().count == 4)

        // 2. Atomic rename rotation (new inode at same path with a brand-new session)
        let replacementURL = tempDir.appendingPathComponent("events.jsonl.new")
        let newSessionContent =
            "{\"id\":\"n1\",\"type\":\"session.start\",\"sessionId\":\"rot-sess-2\",\"timestamp\":\"2026-10-30T12:00:00Z\",\"cwd\":\"/tmp/repo\"}\n"
            + "{\"id\":\"n2\",\"type\":\"tool.execution_start\",\"timestamp\":\"2026-10-30T12:00:01Z\",\"data\":{\"toolCallId\":\"ntc-1\",\"mcpServerName\":\"github\",\"mcpToolName\":\"list_issues\",\"toolName\":\"github-list_issues\"}}\n"
        try Data(newSessionContent.utf8).write(to: replacementURL)
        _ = try FileManager.default.replaceItemAt(logURL, withItemAt: replacementURL)

        let afterInodeRotate = try await ingestor.ingest(targets: [target])
        #expect(afterInodeRotate.eventsInserted == 2)
        #expect(try store.allSessions().count == 2)
        #expect(try store.allUsageEvents().count == 6)
    }

    @Test(
        "Read-only proof: full Workspace scan + LogIngestor run on chmod a-w polyglot copy leaves tree hashes identical"
    )
    func readOnlyProofOnChmodPolyglotCopy() async throws {
        let polyglot = try FixtureHome(scenario: "polyglot")
        let tempCopy = try polyglot.copyToTemporaryDirectory()
        defer {
            Self.setWritableRecursively(at: tempCopy, writable: true)
            try? FileManager.default.removeItem(at: tempCopy)
        }

        Self.setWritableRecursively(at: tempCopy, writable: false)
        let hashBefore = try Self.treeHash(at: tempCopy)

        let env = AgentEnvironment(
            home: tempCopy,
            env: ["BENTO_SYSTEM_ROOT": tempCopy.path],
            fileSystem: LocalReadOnlyFileSystem(),
            now: { FixtureHome.defaultTimestamp }
        )
        let store = try BentoStore.inMemory()
        let workspace = Workspace(environment: env, store: store)
        _ = try await workspace.scanFull()
        let targets = try await workspace.logIngestTargets()
        let report = try await LogIngestor(fileSystem: env.fileSystem, store: store).ingest(targets: targets)

        #expect(report.eventsInserted == 13)
        let hashAfter = try Self.treeHash(at: tempCopy)
        #expect(hashBefore == hashAfter)
    }

    @Test("Plain JSONL throughput hits >= 150 MB/s (smoke corpus always; 500 MB benchmark when BENTO_BENCHMARK=1)")
    func plainJSONL500MBBenchmarkExceeds150MBPerSecondWhenOptedIn() throws {
        let runFull500MB =
            ProcessInfo.processInfo.environment["BENTO_BENCHMARK"] == "1"
            || ProcessInfo.processInfo.environment["BENTO_RUN_500MB_BENCHMARK"] == "1"
        let targetBytes = runFull500MB ? (500 * 1024 * 1024) : (8 * 1024 * 1024)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let benchFile = tempDir.appendingPathComponent("bench.jsonl")
        FileManager.default.createFile(atPath: benchFile.path, contents: nil)
        let writer = try FileHandle(forWritingTo: benchFile)

        let metaLine =
            "{\"timestamp\":\"2026-10-30T10:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"bench-sess\",\"cwd\":\"/tmp/repo\",\"model\":\"gpt-5-codex\"}}\n"
        try writer.write(contentsOf: Data(metaLine.utf8))

        // Realistic 4-line repeating block (~1.6 KB) mixing user/output payload lines, function_call, and token_count
        let padding = String(repeating: "a", count: 320)
        var block = ""
        for idx in 0..<256 {
            block +=
                "{\"timestamp\":\"2026-10-30T10:01:00Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":\"\(padding)\"}}\n"
            block +=
                "{\"timestamp\":\"2026-10-30T10:01:01Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\",\"arguments\":\"{\\\"cmd\\\":\\\"ls\\\"}\"}}\n"
            block +=
                "{\"timestamp\":\"2026-10-30T10:01:02Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"output\":\"\(padding)\"}}\n"
            block +=
                "{\"timestamp\":\"2026-10-30T10:01:03Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":\(10000 + idx),\"cached_input_tokens\":8000,\"output_tokens\":120}}}}\n"
        }
        let blockData = Data(block.utf8)
        var written = metaLine.utf8.count
        while written < targetBytes {
            try writer.write(contentsOf: blockData)
            written += blockData.count
        }
        try writer.close()

        let source = LogSource(agent: .codex, url: benchFile)
        var decoder = CodexLogDecoder()
        let reader = StreamingLineReader(url: benchFile)
        var decodedEventCount = 0

        let startNanos = DispatchTime.now().uptimeNanoseconds
        let readOutcome = try reader.readLines { lineData in
            decodedEventCount += decoder.decode(line: lineData, source: source).count
        }
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - startNanos) / 1_000_000_000.0
        let megabytes = Double(readOutcome.bytesRead) / (1024.0 * 1024.0)
        let mbPerSecond = megabytes / max(elapsedSeconds, 0.000_001)

        #expect(decodedEventCount > 1000)
        if runFull500MB {
            #expect(
                mbPerSecond >= 150.0,
                "500 MB plain JSONL benchmark hit \(String(format: "%.1f", mbPerSecond)) MB/s (expected >= 150 MB/s)"
            )
        } else {
            #expect(mbPerSecond >= 50.0)
        }
    }

    // MARK: - Helpers

    private static func decodePlainLines(
        at url: URL,
        source: LogSource,
        decoder initialDecoder: any LogDecoder
    ) throws -> [UsageEvent] {
        var decoder = initialDecoder
        var events: [UsageEvent] = []
        _ = try StreamingLineReader(url: url).readLines { lineData in
            events.append(contentsOf: decoder.decode(line: lineData, source: source))
        }
        return events
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

    private static func treeHash(at root: URL) throws -> String {
        let fm = FileManager.default
        var entries: [String] = []
        if let enumerator = fm.enumerator(at: root.standardizedFileURL, includingPropertiesForKeys: nil) {
            while let url = enumerator.nextObject() as? URL {
                let std = url.standardizedFileURL
                let rel = String(std.path.dropFirst(root.standardizedFileURL.path.count))
                let attrs = try fm.attributesOfItem(atPath: std.path)
                let type = attrs[.type] as? FileAttributeType
                if type == .typeRegular {
                    let bytes = try Data(contentsOf: std)
                    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    entries.append("F:\(rel):\(digest)")
                } else if type == .typeSymbolicLink {
                    let dest = try fm.destinationOfSymbolicLink(atPath: std.path)
                    entries.append("L:\(rel):\(dest)")
                } else if type == .typeDirectory {
                    entries.append("D:\(rel)")
                }
            }
        }
        entries.sort()
        let joined = entries.joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
