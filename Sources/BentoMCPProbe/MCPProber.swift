import BentoCore
import Foundation

/// Outcome of an explicit-consent MCP probe request (`PLAN.md` §6.4, §11 T10).
public enum MCPProbeOutcome: Sendable, Equatable {
    /// Server was freshly probed and its schemas were persisted to cache (if configured).
    case probed(MCPProbeRecord)
    /// Server matched a valid `mcp_probe` cache entry by `serverConfigHash`; zero spawn/network calls occurred.
    case cached(MCPProbeRecord)
    /// HTTP/SSE server returned `401`/`403` OAuth challenge and was skipped as `"unprobed"` (`PLAN.md` §6.4).
    case skippedOAuth(serverName: String, serverConfigHash: String, statusCode: Int)
}

/// Coordinates explicit-consent verification, `server_config_hash` caching, stdio / Streamable HTTP probing,
/// and tool schema token estimation (`PLAN.md` §6.4, §7, §11 T10).
public struct MCPProber: Sendable {
    public let consentStore: MCPConsentStore
    public let cache: (any MCPProbeCaching)?
    public let timeoutSeconds: TimeInterval
    private let urlSession: URLSession?
    private let now: @Sendable () -> Date

    /// Creates an MCP prober enforcing `consentStore` before every probe.
    public init(
        consentStore: MCPConsentStore,
        cache: (any MCPProbeCaching)? = nil,
        timeoutSeconds: TimeInterval = StdioMCPClient.defaultTimeoutSeconds,
        urlSession: URLSession? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.consentStore = consentStore
        self.cache = cache
        self.timeoutSeconds = min(max(0.05, timeoutSeconds), StdioMCPClient.maxTimeoutCeilingSeconds)
        self.urlSession = urlSession
        self.now = now
    }

    /// Probes `config` after verifying explicit consent in `consentStore`.
    ///
    /// - Important: Never spawns a child process or performs an HTTP request when consent is absent.
    public func probe(
        serverName: String,
        agent: AgentID,
        config: MCPServerConfig,
        workingDirectory: URL,
        homeDirectory: URL,
        basePATH: String? = nil,
        declaredEnvValues: [String: String] = [:],
        model: String? = nil,
        tokenizer: (any TokenCountingProvider)? = nil,
        forceRefresh: Bool = false
    ) async throws -> MCPProbeOutcome {
        let configHash = MCPServerConfigHasher.hash(config)

        // Hard security invariant (PLAN.md §0, §6.4, §7): NEVER probe without explicit consent.
        guard consentStore.hasConsent(forHash: configHash) else {
            throw BentoMCPProbeError.consentRequired(
                serverName: serverName,
                serverConfigHash: configHash
            )
        }

        if !forceRefresh,
            let cachedRecord = try cache?.cachedMCPProbe(forHash: configHash),
            cachedRecord.ok
        {
            return .cached(cachedRecord)
        }

        do {
            let handshake: MCPJSONRPC.HandshakeResult
            switch config.transport {
            case .stdio(let command, let args):
                let stdio = StdioMCPClient(timeoutSeconds: timeoutSeconds)
                handshake = try await stdio.probe(
                    serverName: serverName,
                    command: command,
                    args: args,
                    config: config,
                    workingDirectory: workingDirectory,
                    homeDirectory: homeDirectory,
                    basePATH: basePATH,
                    declaredValues: declaredEnvValues
                )

            case .http(let url), .sse(let url):
                let http = StreamableHTTPMCPClient(
                    timeoutSeconds: timeoutSeconds,
                    urlSession: urlSession
                )
                handshake = try await http.probe(
                    serverName: serverName,
                    urlString: url
                )
            }

            let estimatedTokens = Self.estimateToolsTokens(
                tools: handshake.tools,
                configHash: configHash,
                agent: agent,
                model: model,
                tokenizer: tokenizer
            )

            let record = MCPProbeRecord(
                serverConfigHash: configHash,
                agent: agent,
                serverName: serverName,
                probedAt: now(),
                ok: true,
                error: nil,
                tools: handshake.tools,
                toolsTokensEstimate: estimatedTokens,
                protocolVersion: handshake.protocolVersion
            )
            try cache?.saveMCPProbe(record)
            return .probed(record)
        } catch let probeError as BentoMCPProbeError {
            if case .oauthRequired(_, let statusCode) = probeError {
                return .skippedOAuth(
                    serverName: serverName,
                    serverConfigHash: configHash,
                    statusCode: statusCode
                )
            }

            let failureRecord = MCPProbeRecord(
                serverConfigHash: configHash,
                agent: agent,
                serverName: serverName,
                probedAt: now(),
                ok: false,
                error: probeError.description,
                tools: [],
                toolsTokensEstimate: 0,
                protocolVersion: nil
            )
            try? cache?.saveMCPProbe(failureRecord)
            throw probeError
        }
    }

    private static func estimateToolsTokens(
        tools: [MCPToolSchema],
        configHash: String,
        agent: AgentID,
        model: String?,
        tokenizer: (any TokenCountingProvider)?
    ) -> Int {
        tools.reduce(0) { total, tool in
            let json = tool.canonicalSerializationJSON()
            if let tokenizer {
                let hashKey = "mcp-probe:\(configHash):\(tool.name):\(ContentHasher.sha256Hex(Data(json.utf8)))"
                return total
                    + tokenizer.estimateTokens(
                        text: json,
                        contentHash: hashKey,
                        agent: agent,
                        model: model
                    ).tokens
            }
            return total + max(1, Int((Double(json.utf8.count) / 3.8).rounded()))
        }
    }
}
