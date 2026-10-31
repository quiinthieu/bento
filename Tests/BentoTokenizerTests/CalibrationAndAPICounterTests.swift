import BentoAdapters
import BentoCore
import BentoLogIngest
import BentoScanner
import BentoStore
import BentoTestSupport
import BentoTokenizer
import Foundation
import Synchronization
import Testing

struct CalibrationAndAPICounterTests {
    @Test("Calibration recovers synthetic k = 1.12 within +-0.02 from ingested session logs and persists to BentoStore")
    func calibrationRecoversSyntheticKFactorWithinToleranceAndPersists() async throws {
        let baseFixture = try FixtureHome(scenario: "usage-join")
        let tempHome = try baseFixture.copyToTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let now = Date(timeIntervalSince1970: 1_793_404_800)  // 2026-10-31T00:00:00Z
        let env = AgentEnvironment(
            home: tempHome,
            env: ["BENTO_SYSTEM_ROOT": tempHome.path],
            fileSystem: LocalReadOnlyFileSystem(),
            now: { now }
        )
        let store = try BentoStore.inMemory()
        let workspace = Workspace(environment: env, store: store)
        _ = try await workspace.scanFull()

        let uncalibratedRegistry = try AgentTokenizerRegistry()
        let appRepoURL = tempHome.appendingPathComponent("repos/app").standardizedFileURL
        let protoRepoURL = tempHome.appendingPathComponent("repos/new-prototype").standardizedFileURL

        let uncalibratedAppBudget = try await workspace.budget(
            for: .claudeCode,
            folder: appRepoURL,
            model: "claude-sonnet-4-5",
            tokenizer: uncalibratedRegistry
        )
        let uncalibratedProtoBudget = try await workspace.budget(
            for: .claudeCode,
            folder: protoRepoURL,
            model: "claude-sonnet-4-5",
            tokenizer: uncalibratedRegistry
        )

        let trueK = 1.12
        let deterministicNoise = [-18, 12, -9, 15, -6, 11, -14, 9]
        let userPrompts = [
            String(repeating: "a", count: 80),
            String(repeating: "b", count: 160),
            String(repeating: "c", count: 120),
            String(repeating: "d", count: 200),
            String(repeating: "e", count: 60),
            String(repeating: "f", count: 140),
            String(repeating: "g", count: 100),
            String(repeating: "h", count: 180)
        ]

        // Overwrite fixture logs in tempHome with 8 synthetic Claude sessions generated from trueK = 1.12
        var appLines: [String] = []
        var protoLines: [String] = []

        for idx in 0..<8 {
            let isApp = idx < 5
            let repoURL = isApp ? appRepoURL : protoRepoURL
            let predicted = isApp ? uncalibratedAppBudget.prePromptTokens : uncalibratedProtoBudget.prePromptTokens
            let prompt = userPrompts[idx]
            let estimatedPromptTokens = CalibrationFitter.estimateUserMessageTokens(charCount: prompt.count)
            let totalFirstTurnInput =
                Int((Double(predicted) * trueK).rounded()) + estimatedPromptTokens + deterministicNoise[idx]
            let cacheRead = max(0, totalFirstTurnInput - 2_400)
            let cacheCreate = min(2_000, totalFirstTurnInput - cacheRead)
            let baseInput = max(0, totalFirstTurnInput - cacheRead - cacheCreate)

            let tsUser = String(format: "2026-10-%02dT10:00:00Z", 20 + idx)
            let tsAsst = String(format: "2026-10-%02dT10:00:03Z", 20 + idx)
            let sid = "synth-k-\(idx)"

            let userLine =
                "{\"type\":\"user\",\"sessionId\":\"\(sid)\",\"timestamp\":\"\(tsUser)\",\"cwd\":\"\(repoURL.path)\",\"message\":{\"role\":\"user\",\"content\":\"\(prompt)\"}}"
            let asstLine =
                "{\"type\":\"assistant\",\"sessionId\":\"\(sid)\",\"requestId\":\"req_\(sid)\",\"timestamp\":\"\(tsAsst)\",\"cwd\":\"\(repoURL.path)\",\"message\":{\"id\":\"msg_\(sid)\",\"model\":\"claude-sonnet-4-5\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"usage\":{\"input_tokens\":\(baseInput),\"cache_creation_input_tokens\":\(cacheCreate),\"cache_read_input_tokens\":\(cacheRead),\"output_tokens\":60}}}"

            if isApp {
                appLines.append(userLine)
                appLines.append(asstLine)
            } else {
                protoLines.append(userLine)
                protoLines.append(asstLine)
            }
        }

        let appLogURL = tempHome.appendingPathComponent(".claude/projects/-repos-app/sessions.jsonl")
        let protoLogURL = tempHome.appendingPathComponent(".claude/projects/-repos-new-prototype/sessions.jsonl")
        try Data((appLines.joined(separator: "\n") + "\n").utf8).write(to: appLogURL)
        try Data((protoLines.joined(separator: "\n") + "\n").utf8).write(to: protoLogURL)

        let targets = try await workspace.logIngestTargets(for: .claudeCode)
        _ = try await LogIngestor(fileSystem: env.fileSystem, store: store).ingest(targets: targets)

        let sessions = try store.calibrationSessions(agent: .claudeCode)
        #expect(sessions.count == 8)
        #expect(sessions.allSatisfy { ($0.firstUserMessageCharCount ?? 0) > 0 })

        var samples: [CalibrationSample] = []
        for session in sessions {
            guard let cwd = session.cwd, let firstTurn = session.firstTurnInput else { continue }
            let sessionFolder = URL(fileURLWithPath: cwd).standardizedFileURL
            let uncalibrated = try await workspace.budget(
                for: session.agent,
                folder: sessionFolder,
                model: session.model,
                tokenizer: uncalibratedRegistry
            )
            let modelName = uncalibrated.model ?? session.model ?? "*"
            let baseID = uncalibratedRegistry.baseCounterID(for: session.agent, model: modelName)
            let userTokens = CalibrationFitter.estimateUserMessageTokens(
                charCount: session.firstUserMessageCharCount
            )
            samples.append(
                CalibrationSample(
                    agent: session.agent,
                    sessionID: session.sessionID,
                    model: modelName,
                    tokenizerID: baseID,
                    predictedPrePromptTokens: uncalibrated.prePromptTokens,
                    measuredFirstTurnInput: firstTurn,
                    userMessageEstimatedTokens: userTokens
                )
            )
        }

        let fittedRecords = CalibrationFitter(minimumSamples: 3).fit(samples: samples, now: now)
        #expect(fittedRecords.count == 1)
        let record = try #require(fittedRecords.first)
        #expect(record.agent == .claudeCode)
        #expect(record.model == "claude-sonnet-4-5")
        #expect(record.tokenizerID == "heuristic")
        #expect(record.sampleCount == 8)
        #expect(
            abs(record.kFactor - trueK) <= 0.02,
            "Expected fitted k within +-0.02 of \(trueK), got \(record.kFactor)"
        )

        // Persist in BentoStore `calibration` table and reload into AgentTokenizerRegistry
        try store.upsertCalibrations(fittedRecords)
        let storedCalibrations = try store.calibrations(for: .claudeCode)
        #expect(storedCalibrations.count == 1)
        let reloadedRecord = try #require(storedCalibrations.first)
        #expect(abs(reloadedRecord.kFactor - record.kFactor) < 0.000_001)
        #expect(reloadedRecord.sampleCount == 8)

        var calibratedRegistry = try AgentTokenizerRegistry()
        calibratedRegistry.applyCalibrations(storedCalibrations)
        let estimate = calibratedRegistry.estimateTokens(
            text: "Verify schema migrations in an isolated transaction and report index changes.",
            contentHash: nil,
            agent: .claudeCode,
            model: "claude-sonnet-4-5"
        )
        #expect(estimate.confidence == .estimated)
        #expect(estimate.method.contains("calibrated k=1.12"))
    }

    @Test(
        "Opt-in AnthropicCountTokens and GeminiCountTokens cache by content hash, return exact counts, and never call network when disabled"
    )
    func optInAPICountersCacheByContentHashAndRefuseWhenDisabled() async throws {
        MockTokenCountURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockTokenCountURLProtocol.self]
        let mockSession = URLSession(configuration: config)

        let keyStore = InMemoryAPIKeyStore()

        // 1. Disabled or missing key -> refuses with zero HTTP requests
        let disabledAnthropic = AnthropicCountTokens(
            isEnabled: false,
            keyProvider: keyStore,
            session: mockSession
        )
        await #expect(throws: TokenCountAPIError.self) {
            _ = try await disabledAnthropic.countTokens(text: "Hello world", model: "claude-sonnet-4-5")
        }
        #expect(MockTokenCountURLProtocol.requestCount == 0)

        let missingKeyAnthropic = AnthropicCountTokens(
            isEnabled: true,
            keyProvider: keyStore,
            session: mockSession
        )
        await #expect(throws: TokenCountAPIError.self) {
            _ = try await missingKeyAnthropic.countTokens(text: "Hello world", model: "claude-sonnet-4-5")
        }
        #expect(MockTokenCountURLProtocol.requestCount == 0)

        // 2. Enabled with key -> Anthropic POST /v1/messages/count_tokens returns exact count and caches by contentHash
        try keyStore.setAPIKey("test-anthropic-key-placeholder", for: .anthropic)
        try keyStore.setAPIKey("test-gemini-key-placeholder", for: .gemini)

        let anthropic = AnthropicCountTokens(
            isEnabled: true,
            keyProvider: keyStore,
            session: mockSession
        )
        let textA = "Always run swift test and swift format lint before opening a PR."
        let hashA = ContentHasher.sha256NormalizedText(textA)

        let antEst1 = try await anthropic.countTokens(
            text: textA,
            contentHash: hashA,
            model: "claude-sonnet-4-5"
        )
        #expect(antEst1.tokens == 42)
        #expect(antEst1.confidence == .exact)
        #expect(antEst1.range == nil)
        #expect(MockTokenCountURLProtocol.requestCount == 1)

        // Second call with identical contentHash hits cache with 0 additional HTTP requests!
        let antEst2 = try await anthropic.countTokens(
            text: textA,
            contentHash: hashA,
            model: "claude-sonnet-4-5"
        )
        #expect(antEst2.tokens == 42)
        #expect(MockTokenCountURLProtocol.requestCount == 1)

        // 3. Enabled Gemini POST .../models/{model}:countTokens returns exact count and works through AgentTokenizerRegistry
        let gemini = GeminiCountTokens(
            isEnabled: true,
            keyProvider: keyStore,
            session: mockSession
        )
        let gemEst1 = try await gemini.countTokens(
            text: textA,
            contentHash: hashA,
            model: "gemini-2.5-pro"
        )
        #expect(gemEst1.tokens == 37)
        #expect(gemEst1.confidence == .exact)
        #expect(gemEst1.range == nil)
        #expect(MockTokenCountURLProtocol.requestCount == 2)

        var registry = try AgentTokenizerRegistry()
        registry.setExactAPICounter(anthropic, for: .claudeCode)
        registry.setExactAPICounter(gemini, for: .gemini)

        let regClaude = registry.estimateTokens(
            text: "New uncached rule text for Claude.",
            contentHash: "hash-new-claude",
            agent: .claudeCode,
            model: "claude-sonnet-4-5"
        )
        #expect(regClaude.confidence == .exact)
        #expect(regClaude.range == nil)
        #expect(regClaude.tokens == 42)

        let regGemini = registry.estimateTokens(
            text: "New uncached rule text for Gemini.",
            contentHash: "hash-new-gemini",
            agent: .gemini,
            model: "gemini-2.5-pro"
        )
        #expect(regGemini.confidence == .exact)
        #expect(regGemini.range == nil)
        #expect(regGemini.tokens == 37)
        #expect(MockTokenCountURLProtocol.requestCount == 4)
    }
}

private final class MockTokenCountURLProtocol: URLProtocol, @unchecked Sendable {
    private static let counter = Mutex(0)

    static var requestCount: Int {
        counter.withLock { $0 }
    }

    static func reset() {
        counter.withLock { $0 = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.counter.withLock { $0 += 1 }
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let payload: String
        let statusCode: Int
        if url.host == "api.anthropic.com" && url.path == "/v1/messages/count_tokens" {
            let hasKey = !(request.value(forHTTPHeaderField: "x-api-key") ?? "").isEmpty
            let hasVersion = request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01"
            statusCode = (hasKey && hasVersion && request.httpMethod == "POST") ? 200 : 401
            payload = "{\"input_tokens\":42}"
        } else if url.host == "generativelanguage.googleapis.com" && url.path.hasSuffix(":countTokens") {
            let hasKey = !(request.value(forHTTPHeaderField: "x-goog-api-key") ?? "").isEmpty
            statusCode = (hasKey && request.httpMethod == "POST") ? 200 : 401
            payload = "{\"totalTokens\":37}"
        } else {
            statusCode = 404
            payload = "{\"error\":\"unknown endpoint\"}"
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
