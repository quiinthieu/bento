import BentoAdapters
import BentoCore
import BentoMCPProbe
import BentoScanner
import BentoStore
import BentoTestSupport
import BentoTokenizer
import Darwin
import Foundation
import Testing

struct BentoMCPProbeTests {
    private static var fakeServerScriptPath: String {
        FixtureHome.repositoryRoot()
            .appendingPathComponent("Fixtures/mcp/fake-server/server.py")
            .standardizedFileURL
            .path
    }

    @Test("Prober refuses without consent and invalidates consent when command, args, or envKeys change")
    func refusesWithoutConsentAndInvalidatesOnConfigChange() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-mcp-consent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let markerFile = tempDir.appendingPathComponent("spawn-marker.txt")
        let baseConfig = MCPServerConfig(
            transport: .stdio(
                command: "/usr/bin/python3",
                args: [Self.fakeServerScriptPath, "--mode", "normal", "--marker-file", markerFile.path]
            ),
            envKeys: ["API_KEY"]
        )

        let store = try BentoStore.inMemory()
        let consentStore = try MCPConsentStore(persistence: store)
        let tokenizer = try AgentTokenizerRegistry()
        let prober = MCPProber(consentStore: consentStore, cache: store)
        let baseHash = MCPServerConfigHasher.hash(baseConfig)

        await #expect(throws: BentoMCPProbeError.consentRequired(serverName: "fake", serverConfigHash: baseHash)) {
            _ = try await prober.probe(
                serverName: "fake",
                agent: .codex,
                config: baseConfig,
                workingDirectory: tempDir,
                homeDirectory: tempDir,
                declaredEnvValues: [:],
                tokenizer: tokenizer
            )
        }
        #expect(
            !FileManager.default.fileExists(atPath: markerFile.path),
            "Unconsented probe MUST NEVER spawn child process"
        )

        // Grant consent for baseConfig and verify persisted consent round-trips into a fresh MCPConsentStore.
        try consentStore.grantConsent(for: baseConfig)
        let reloadedConsentStore = try MCPConsentStore(persistence: store)
        #expect(reloadedConsentStore.hasConsent(for: baseConfig))

        // Mutating command, args, or envKeys must produce distinct hashes and require fresh consent.
        let changedCommand = MCPServerConfig(
            transport: .stdio(command: "python3", args: ["--version"]),
            envKeys: ["API_KEY"]
        )
        let changedArgs = MCPServerConfig(
            transport: .stdio(
                command: "/usr/bin/python3",
                args: [Self.fakeServerScriptPath, "--mode", "normal", "--tools", "4"]
            ),
            envKeys: ["API_KEY"]
        )
        let changedEnvKeys = MCPServerConfig(
            transport: baseConfig.transport,
            envKeys: ["API_KEY", "EXTRA_TOKEN"]
        )

        #expect(MCPServerConfigHasher.hash(changedCommand) != baseHash)
        #expect(MCPServerConfigHasher.hash(changedArgs) != baseHash)
        #expect(MCPServerConfigHasher.hash(changedEnvKeys) != baseHash)
        #expect(!reloadedConsentStore.hasConsent(for: changedCommand))
        #expect(!reloadedConsentStore.hasConsent(for: changedArgs))
        #expect(!reloadedConsentStore.hasConsent(for: changedEnvKeys))
    }

    @Test("Stdio handshake returns tool schemas, tokenizes {name, description, inputSchema}, and filters activeTools")
    func stdioNormalHandshakeAndToolTokenization() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-mcp-normal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = MCPServerConfig(
            transport: .stdio(
                command: "/usr/bin/python3",
                args: [Self.fakeServerScriptPath, "--mode", "normal", "--tools", "3"]
            ),
            allowedTools: ["tool_0", "tool_2"],
            disabledTools: ["tool_2"]
        )
        let consentStore = try MCPConsentStore()
        try consentStore.grantConsent(for: config)
        let tokenizer = try AgentTokenizerRegistry()
        let prober = MCPProber(consentStore: consentStore)

        let outcome = try await prober.probe(
            serverName: "docs",
            agent: .codex,
            config: config,
            workingDirectory: tempDir,
            homeDirectory: tempDir,
            declaredEnvValues: [:],
            model: "gpt-5-codex",
            tokenizer: tokenizer
        )

        guard case .probed(let record) = outcome else {
            Issue.record("Expected .probed outcome, got \(outcome)")
            return
        }

        #expect(record.ok)
        #expect(record.error == nil)
        #expect(record.protocolVersion == "2025-03-26")
        #expect(record.tools.map(\.name) == ["tool_0", "tool_1", "tool_2"])
        #expect(record.toolsTokensEstimate > 0)

        for tool in record.tools {
            let json = tool.canonicalSerializationJSON()
            #expect(json.contains("\"name\""))
            #expect(json.contains("\"description\""))
            #expect(json.contains("\"inputSchema\""))
        }

        let active = record.activeTools(for: config)
        #expect(active.map(\.name) == ["tool_0"])
    }

    @Test("Stdio tools/list follows nextCursor pagination until exhausted")
    func stdioPaginationCollectsAllPages() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-mcp-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = MCPServerConfig(
            transport: .stdio(
                command: "/usr/bin/python3",
                args: [Self.fakeServerScriptPath, "--mode", "paginate", "--tools", "5", "--page-size", "2"]
            )
        )
        let consentStore = try MCPConsentStore()
        try consentStore.grantConsent(for: config)
        let tokenizer = try AgentTokenizerRegistry()
        let prober = MCPProber(consentStore: consentStore)

        let outcome = try await prober.probe(
            serverName: "paginated",
            agent: .claudeCode,
            config: config,
            workingDirectory: tempDir,
            homeDirectory: tempDir,
            declaredEnvValues: [:],
            tokenizer: tokenizer
        )

        guard case .probed(let record) = outcome else {
            Issue.record("Expected .probed outcome, got \(outcome)")
            return
        }

        #expect(record.tools.map(\.name) == ["tool_0", "tool_1", "tool_2", "tool_3", "tool_4"])
        #expect(record.toolsTokensEstimate > 100)
    }

    @Test("Stdio timeout ceiling is <= 15s + 1s and hung servers terminate cleanly on timeout")
    func stdioTimeoutTerminatesHungServerWithinCeiling() async throws {
        #expect(StdioMCPClient.defaultTimeoutSeconds == 15.0)
        #expect(StdioMCPClient.maxTimeoutCeilingSeconds <= 16.0)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-mcp-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let markerFile = tempDir.appendingPathComponent("pid.txt")
        let config = MCPServerConfig(
            transport: .stdio(
                command: "/usr/bin/python3",
                args: [
                    Self.fakeServerScriptPath,
                    "--mode", "sleep",
                    "--seconds", "30",
                    "--marker-file", markerFile.path
                ]
            )
        )
        let consentStore = try MCPConsentStore()
        try consentStore.grantConsent(for: config)
        let prober = MCPProber(consentStore: consentStore, timeoutSeconds: 0.4)

        let start = ContinuousClock.now
        do {
            _ = try await prober.probe(
                serverName: "sleeper",
                agent: .codex,
                config: config,
                workingDirectory: tempDir,
                homeDirectory: tempDir,
                declaredEnvValues: [:]
            )
            Issue.record("Expected BentoMCPProbeError.timedOut")
        } catch let error as BentoMCPProbeError {
            guard case .timedOut(let serverName, let seconds, _) = error else {
                Issue.record("Expected .timedOut, got \(error)")
                return
            }
            #expect(serverName == "sleeper")
            #expect(seconds <= 16.0)
        }

        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(4))

        // Verify spawned child process was terminated cleanly (kill(pid, 0) != 0).
        if let rawMarker = try? String(contentsOf: markerFile, encoding: .utf8),
            let pidString = rawMarker.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").last,
            let pid = pid_t(pidString)
        {
            // Give OS up to 200ms to reap process table entry.
            var stillAlive = Darwin.kill(pid, 0) == 0
            if stillAlive {
                try await Task.sleep(for: .milliseconds(200))
                stillAlive = Darwin.kill(pid, 0) == 0
            }
            #expect(!stillAlive, "Timed-out MCP child process \(pid) must not remain running")
        }
    }

    @Test("Stdio server crash surfaces exit code and caps captured stderr to bounded buffer")
    func stdioCrashCapturesBoundedStderrDiagnostic() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-mcp-crash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = MCPServerConfig(
            transport: .stdio(
                command: "/usr/bin/python3",
                args: [
                    Self.fakeServerScriptPath,
                    "--mode", "crash",
                    "--exit-code", "42",
                    "--stderr-bytes", "40000"
                ]
            )
        )
        let store = try BentoStore.inMemory()
        let consentStore = try MCPConsentStore(persistence: store)
        try consentStore.grantConsent(for: config)
        let prober = MCPProber(consentStore: consentStore, cache: store)

        do {
            _ = try await prober.probe(
                serverName: "crashy",
                agent: .gemini,
                config: config,
                workingDirectory: tempDir,
                homeDirectory: tempDir,
                declaredEnvValues: [:]
            )
            Issue.record("Expected BentoMCPProbeError.processCrashed")
        } catch let error as BentoMCPProbeError {
            guard case .processCrashed(let serverName, let exitCode, let stderr) = error else {
                Issue.record("Expected .processCrashed, got \(error)")
                return
            }
            #expect(serverName == "crashy")
            #expect(exitCode == 42)
            #expect(stderr.contains("FAKE_MCP_CRASH"))
            #expect(stderr.utf8.count <= StdioMCPClient.maxStderrBytes)
        }

        // Failed probe record is recorded with ok == false in BentoStore.
        let persisted = try #require(try store.cachedMCPProbe(forHash: MCPServerConfigHasher.hash(config)))
        #expect(!persisted.ok)
        #expect(persisted.error?.contains("42") == true)
    }

    @Test("Stdio environment scrubbing exposes only PATH, HOME, and declared envKeys with cwd=repo and no TTY")
    func stdioScrubsEnvironmentAndSetsRepoWorkingDirectoryWithoutTTY() async throws {
        setenv("BENTO_CANARY_HOST_SECRET", "must-never-leak-into-mcp-child", 1)
        defer { unsetenv("BENTO_CANARY_HOST_SECRET") }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-mcp-scrub-\(UUID().uuidString)", isDirectory: true)
        let fakeHome = tempRoot.appendingPathComponent("home", isDirectory: true)
        let fakeRepo = tempRoot.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let config = MCPServerConfig(
            transport: .stdio(
                command: "/usr/bin/python3",
                args: [Self.fakeServerScriptPath, "--mode", "dump-env"]
            ),
            envKeys: ["DECLARED_SERVICE_TOKEN"]
        )
        let consentStore = try MCPConsentStore()
        try consentStore.grantConsent(for: config)
        let prober = MCPProber(consentStore: consentStore)

        let outcome = try await prober.probe(
            serverName: "env-inspector",
            agent: .claudeCode,
            config: config,
            workingDirectory: fakeRepo,
            homeDirectory: fakeHome,
            declaredEnvValues: [
                "DECLARED_SERVICE_TOKEN": "value-from-agent-config",
                "UNDECLARED_EXTRA_KEY": "must-be-dropped"
            ]
        )

        guard case .probed(let record) = outcome,
            let description = record.tools.first?.description,
            let data = description.data(using: .utf8),
            let report = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let childEnv = report["env"] as? [String: String],
            let childCwd = report["cwd"] as? String,
            let isatty = report["isatty"] as? Bool
        else {
            Issue.record("Failed to decode dump-env tool report")
            return
        }

        #expect(!isatty, "MCP stdio child must never inherit a controlling TTY")
        #expect(
            URL(fileURLWithPath: childCwd).resolvingSymlinksInPath().path
                == fakeRepo.resolvingSymlinksInPath().path
        )
        #expect(childEnv["HOME"] == fakeHome.path)
        #expect(childEnv["PATH"] != nil)
        #expect(childEnv["DECLARED_SERVICE_TOKEN"] == "value-from-agent-config")
        #expect(childEnv["BENTO_CANARY_HOST_SECRET"] == nil, "Host environment leaked into MCP child!")
        #expect(childEnv["UNDECLARED_EXTRA_KEY"] == nil, "Undeclared env value leaked into MCP child!")
        #expect(childEnv["SSH_AUTH_SOCK"] == nil)
        #expect(childEnv["USER"] == nil)
        #expect(childEnv["SHELL"] == nil)
    }

    @Test("Cache hit by server_config_hash in BentoStore returns cached tools with zero process spawn")
    func cacheHitByConfigHashSkipsSecondSpawn() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-mcp-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let markerFile = tempDir.appendingPathComponent("spawns.log")
        let config = MCPServerConfig(
            transport: .stdio(
                command: "/usr/bin/python3",
                args: [
                    Self.fakeServerScriptPath,
                    "--mode", "normal",
                    "--tools", "2",
                    "--marker-file", markerFile.path
                ]
            )
        )

        let store = try BentoStore.inMemory()
        let consentStore = try MCPConsentStore(persistence: store)
        try consentStore.grantConsent(for: config)
        let tokenizer = try AgentTokenizerRegistry()
        let prober = MCPProber(consentStore: consentStore, cache: store)

        let first = try await prober.probe(
            serverName: "cached-srv",
            agent: .codex,
            config: config,
            workingDirectory: tempDir,
            homeDirectory: tempDir,
            declaredEnvValues: [:],
            tokenizer: tokenizer
        )
        guard case .probed(let firstRecord) = first else {
            Issue.record("Expected first call to spawn and return .probed")
            return
        }

        let markerLinesAfterFirst = try String(contentsOf: markerFile, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        #expect(markerLinesAfterFirst.count == 1)

        let second = try await prober.probe(
            serverName: "cached-srv",
            agent: .codex,
            config: config,
            workingDirectory: tempDir,
            homeDirectory: tempDir,
            declaredEnvValues: [:],
            tokenizer: tokenizer
        )
        guard case .cached(let secondRecord) = second else {
            Issue.record("Expected second call to hit BentoStore cache and return .cached")
            return
        }

        let markerLinesAfterSecond = try String(contentsOf: markerFile, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        #expect(markerLinesAfterSecond.count == 1, "Cache hit must perform zero child spawns")
        #expect(secondRecord.tools == firstRecord.tools)
        #expect(secondRecord.toolsTokensEstimate == firstRecord.toolsTokensEstimate)
    }

    @Test("Streamable HTTP client supports JSON, SSE event-stream framing, pagination, and skips OAuth 401/403")
    func streamableHTTPHandlesJSONAndSSEAndSkipsOAuth() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockMCPHTTPProtocol.self]
        let session = URLSession(configuration: sessionConfig)

        let jsonConfig = MCPServerConfig(transport: .http(url: "https://mcp.example.test/json"))
        let sseConfig = MCPServerConfig(transport: .sse(url: "https://mcp.example.test/sse"))
        let oauthConfig = MCPServerConfig(transport: .http(url: "https://mcp.example.test/oauth"))

        let store = try BentoStore.inMemory()
        let consentStore = try MCPConsentStore(persistence: store)
        try consentStore.grantConsent(for: jsonConfig)
        try consentStore.grantConsent(for: sseConfig)
        try consentStore.grantConsent(for: oauthConfig)

        let tokenizer = try AgentTokenizerRegistry()
        let prober = MCPProber(consentStore: consentStore, cache: store, urlSession: session)
        let tempDir = FileManager.default.temporaryDirectory

        // 1. JSON + pagination + Mcp-Session-Id header round-trip
        let jsonOutcome = try await prober.probe(
            serverName: "remote-json",
            agent: .claudeCode,
            config: jsonConfig,
            workingDirectory: tempDir,
            homeDirectory: tempDir,
            declaredEnvValues: [:],
            tokenizer: tokenizer
        )
        guard case .probed(let jsonRecord) = jsonOutcome else {
            Issue.record("Expected .probed for remote-json")
            return
        }
        #expect(jsonRecord.tools.map(\.name) == ["http_search", "http_fetch"])

        // 2. text/event-stream SSE response framing
        let sseOutcome = try await prober.probe(
            serverName: "remote-sse",
            agent: .copilot,
            config: sseConfig,
            workingDirectory: tempDir,
            homeDirectory: tempDir,
            declaredEnvValues: [:],
            tokenizer: tokenizer
        )
        guard case .probed(let sseRecord) = sseOutcome else {
            Issue.record("Expected .probed for remote-sse")
            return
        }
        #expect(sseRecord.tools.map(\.name) == ["sse_query"])

        // 3. OAuth 401 server is skipped and marked unprobed (not cached as 0-token ok probe)
        let oauthOutcome = try await prober.probe(
            serverName: "remote-oauth",
            agent: .claudeCode,
            config: oauthConfig,
            workingDirectory: tempDir,
            homeDirectory: tempDir,
            declaredEnvValues: [:],
            tokenizer: tokenizer
        )
        guard case .skippedOAuth(let skippedName, _, let statusCode) = oauthOutcome else {
            Issue.record("Expected .skippedOAuth for 401 server, got \(oauthOutcome)")
            return
        }
        #expect(skippedName == "remote-oauth")
        #expect(statusCode == 401)
        #expect(try store.cachedMCPProbe(forHash: MCPServerConfigHasher.hash(oauthConfig)) == nil)
    }

    @Test("BudgetEngine uses probed tool counts, median fallback for unprobed servers, and Claude auto-defer threshold")
    func budgetEngineAppliesProbedCountsMedianFallbackAndClaudeAutoDefer() throws {
        let store = try BentoStore.inMemory()
        let tokenizer = try AgentTokenizerRegistry()

        let probedConfig = MCPServerConfig(
            transport: .stdio(command: "fake-mcp-a", args: ["--serve"])
        )
        let unprobedConfig = MCPServerConfig(
            transport: .stdio(command: "fake-mcp-b", args: ["--serve"])
        )

        let probedHash = MCPServerConfigHasher.hash(probedConfig)
        let heavyDescription = String(
            repeating: "Detailed schema documentation for enterprise search tool. ",
            count: 40
        )
        let tools = (0..<4).map { idx in
            MCPToolSchema(
                name: "search_\(idx)",
                description: heavyDescription,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "q": .object(["type": .string("string")])
                    ])
                ])
            )
        }
        let estimatedTotal = tools.reduce(0) { acc, tool in
            acc
                + tokenizer.estimateTokens(
                    text: tool.canonicalSerializationJSON(),
                    contentHash: nil,
                    agent: .claudeCode,
                    model: nil
                ).tokens
        }

        let probeRecord = MCPProbeRecord(
            serverConfigHash: probedHash,
            agent: .claudeCode,
            serverName: "alpha",
            probedAt: Date(timeIntervalSince1970: 1_760_000_000),
            ok: true,
            error: nil,
            tools: tools,
            toolsTokensEstimate: estimatedTotal,
            protocolVersion: "2025-03-26"
        )
        try store.saveMCPProbe(probeRecord)

        let fallback = try #require(try store.mcpFallbackEstimate())
        #expect(fallback.sampleServerCount == 1)
        #expect(fallback.medianToolsPerServer == 4)
        #expect(fallback.medianTokensPerTool > 100)

        let locA = SourceLocation(
            path: "/repo/.mcp.json",
            realPath: "/repo/.mcp.json",
            keyPath: ["mcpServers", "alpha"]
        )
        let locB = SourceLocation(
            path: "/repo/.mcp.json",
            realPath: "/repo/.mcp.json",
            keyPath: ["mcpServers", "beta"]
        )
        let idA = ArtifactID(
            agent: .claudeCode,
            kind: .mcpServer,
            scope: .project,
            path: locA.path,
            keyPath: locA.keyPath
        )
        let idB = ArtifactID(
            agent: .claudeCode,
            kind: .mcpServer,
            scope: .project,
            path: locB.path,
            keyPath: locB.keyPath
        )
        let artA = Artifact(
            id: idA,
            agent: .claudeCode,
            kind: .mcpServer,
            scope: .project,
            name: "alpha",
            location: locA,
            contentHash: "hash-a",
            enabled: true,
            loadMode: .always,
            payload: .mcpServer(probedConfig)
        )
        let artB = Artifact(
            id: idB,
            agent: .claudeCode,
            kind: .mcpServer,
            scope: .project,
            name: "beta",
            location: locB,
            contentHash: "hash-b",
            enabled: true,
            loadMode: .always,
            payload: .mcpServer(unprobedConfig)
        )
        let resolution = Resolution(
            agent: .claudeCode,
            folder: "/repo",
            ordered: [
                ResolvedArtifact(artifactID: artA.id, effectiveLoadMode: .always, reason: "approved"),
                ResolvedArtifact(artifactID: artB.id, effectiveLoadMode: .always, reason: "approved")
            ],
            shadowed: [],
            warnings: []
        )

        // 1. Default 10% threshold (20,000 tokens on 200k window): total < 20,000 -> both stay mcpToolsLoaded
        let loadedBudget = try BudgetEngine().computeBudget(
            adapter: ClaudeCodeAdapter(),
            artifacts: [artA, artB],
            resolution: resolution,
            tokenizer: tokenizer,
            mcpProbesByConfigHash: [probedHash: probeRecord],
            mcpFallbackEstimate: fallback
        )
        let alphaLoaded = try #require(loadedBudget.items.first { $0.label == "alpha" })
        let betaLoaded = try #require(loadedBudget.items.first { $0.label == "beta" })
        #expect(alphaLoaded.category == .mcpToolsLoaded)
        #expect(alphaLoaded.tokens == estimatedTotal)
        #expect(alphaLoaded.method.hasPrefix("probed (4 tools,"))
        #expect(betaLoaded.category == .mcpToolsLoaded)
        #expect(betaLoaded.tokens == fallback.estimatedServerTokens(for: unprobedConfig))
        #expect(betaLoaded.method.contains("median fallback from 1 probed server"))

        // 2. With ENABLE_TOOL_SEARCH=auto:1 (1% of 200k = 2,000 tokens), aggregate exceeds threshold -> auto-deferred!
        let autoDeferredBudget = try BudgetEngine().computeBudget(
            adapter: ClaudeCodeAdapter(),
            artifacts: [artA, artB],
            resolution: resolution,
            tokenizer: tokenizer,
            mcpProbesByConfigHash: [probedHash: probeRecord],
            mcpFallbackEstimate: fallback,
            environment: ["ENABLE_TOOL_SEARCH": "auto:1"]
        )
        let hasAlphaStub = autoDeferredBudget.items.contains {
            $0.label == "alpha (tool-search stub)" && $0.category == .mcpToolsLoaded && $0.countsTowardPrePrompt
        }
        let hasAlphaDeferred = autoDeferredBudget.items.contains {
            $0.label == "alpha (deferred tools)" && $0.category == .mcpToolsDeferred && !$0.countsTowardPrePrompt
                && $0.tokens == estimatedTotal
        }
        #expect(hasAlphaStub)
        #expect(hasAlphaDeferred)
    }
}

// MARK: - Mock Streamable HTTP URLProtocol

private final class MockMCPHTTPProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "mcp.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let bodyData = Self.readBody(from: request)
        let payload = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
        let method = payload?["method"] as? String ?? ""
        let reqID = payload?["id"]
        let params = payload?["params"] as? [String: Any]

        if url.path == "/oauth" {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 401,
                httpVersion: "HTTP/1.1",
                headerFields: ["WWW-Authenticate": "Bearer realm=\"mcp\""]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if url.path == "/json" {
            var headers = ["Content-Type": "application/json"]
            let responseBody: Data
            if method == "initialize" {
                headers["Mcp-Session-Id"] = "sess-123"
                responseBody = Self.encodeJSON([
                    "jsonrpc": "2.0",
                    "id": reqID ?? 1,
                    "result": [
                        "protocolVersion": "2025-03-26",
                        "capabilities": ["tools": [:]],
                        "serverInfo": ["name": "mock-http", "version": "1.0"]
                    ]
                ])
            } else if method == "notifications/initialized" {
                let response = HTTPURLResponse(url: url, statusCode: 202, httpVersion: "HTTP/1.1", headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            } else if method == "tools/list" {
                let sessionHeader = request.value(forHTTPHeaderField: "Mcp-Session-Id")
                guard sessionHeader == "sess-123" else {
                    let bad = HTTPURLResponse(url: url, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: nil)!
                    client?.urlProtocol(self, didReceive: bad, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
                if (params?["cursor"] as? String) == "page2" {
                    responseBody = Self.encodeJSON([
                        "jsonrpc": "2.0",
                        "id": reqID ?? 3,
                        "result": [
                            "tools": [
                                [
                                    "name": "http_fetch",
                                    "description": "Fetches a document by URL.",
                                    "inputSchema": ["type": "object"]
                                ]
                            ]
                        ]
                    ])
                } else {
                    responseBody = Self.encodeJSON([
                        "jsonrpc": "2.0",
                        "id": reqID ?? 2,
                        "result": [
                            "tools": [
                                [
                                    "name": "http_search",
                                    "description": "Searches indexed HTTP docs.",
                                    "inputSchema": ["type": "object"]
                                ]
                            ],
                            "nextCursor": "page2"
                        ]
                    ])
                }
            } else {
                responseBody = Data()
            }

            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseBody)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if url.path == "/sse" {
            if method == "notifications/initialized" {
                let response = HTTPURLResponse(url: url, statusCode: 202, httpVersion: "HTTP/1.1", headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }

            let eventPayload: [String: Any]
            if method == "initialize" {
                eventPayload = [
                    "jsonrpc": "2.0",
                    "id": reqID ?? 1,
                    "result": [
                        "protocolVersion": "2025-03-26",
                        "capabilities": ["tools": [:]],
                        "serverInfo": ["name": "mock-sse", "version": "1.0"]
                    ]
                ]
            } else {
                eventPayload = [
                    "jsonrpc": "2.0",
                    "id": reqID ?? 2,
                    "result": [
                        "tools": [
                            [
                                "name": "sse_query",
                                "description": "Streams query results over SSE.",
                                "inputSchema": ["type": "object"]
                            ]
                        ]
                    ]
                ]
            }

            let jsonString = String(decoding: Self.encodeJSON(eventPayload), as: UTF8.self)
            let sseFrame = "event: message\ndata: \(jsonString)\n\n"
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(sseFrame.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let notFound = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: notFound, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data
    }

    private static func encodeJSON(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }
}
