import BentoAdapters
import BentoCore
import Foundation

/// Active MCP server resolved for a target folder, paired with its originating `Artifact` and `MCPServerConfig`.
public struct ResolvedMCPServerTarget: Sendable {
    public var agent: AgentID
    public var artifact: Artifact
    public var config: MCPServerConfig

    public init(agent: AgentID, artifact: Artifact, config: MCPServerConfig) {
        self.agent = agent
        self.artifact = artifact
        self.config = config
    }
}

extension Workspace {
    /// Returns the `FixSupport` capabilities declared by `agent`'s registered adapter.
    nonisolated public func fixSupport(for agent: AgentID) -> FixSupport {
        adaptersByID[agent]?.fixSupport() ?? FixSupport()
    }

    /// Returns all registered `AgentID`s whose adapters advertise `.budget` capability in registration order.
    nonisolated public func budgetCapableAgents() -> [AgentID] {
        adapters
            .filter { $0.capabilities.contains(.budget) }
            .map { type(of: $0).id }
    }

    /// Resolves `(artifacts, resolution)` for `agent` in `folder`, reusing cached `Snapshot` resolution when available.
    public func resolvedContext(
        for agent: AgentID,
        folder: URL
    ) async throws -> (artifacts: [Artifact], resolution: Resolution) {
        guard adaptersByID[agent] != nil else {
            throw BentoScannerError.unknownAgent(agent)
        }
        return try await loadArtifactsAndResolution(for: agent, folder: folder)
    }

    /// Computes the context token `Budget` for `agent` in `folder`, reusing cached `Snapshot` resolution when available.
    public func budget(
        for agent: AgentID,
        folder: URL,
        model: String? = nil,
        tokenizer: any TokenCountingProvider,
        mcpProbesByConfigHash: [String: MCPProbeRecord] = [:],
        mcpFallbackEstimate: MCPFallbackEstimate? = nil,
        measuredFirstTurnInput: Int? = nil
    ) async throws -> Budget {
        guard let adapter = adaptersByID[agent] else {
            throw BentoScannerError.unknownAgent(agent)
        }
        guard adapter.capabilities.contains(.budget) else {
            throw BentoScannerError.budgetUnsupported(agent)
        }

        let (artifacts, resolution) = try await loadArtifactsAndResolution(for: agent, folder: folder)

        return try BudgetEngine().computeBudget(
            adapter: adapter,
            artifacts: artifacts,
            resolution: resolution,
            model: model,
            tokenizer: tokenizer,
            mcpProbesByConfigHash: mcpProbesByConfigHash,
            mcpFallbackEstimate: mcpFallbackEstimate,
            environment: environment.env,
            measuredFirstTurnInput: measuredFirstTurnInput
        )
    }

    /// Computes context token `Budget` breakdowns across all registered budget-capable adapters in `folder`.
    public func budgets(
        folder: URL,
        model: String? = nil,
        tokenizer: any TokenCountingProvider,
        mcpProbesByConfigHash: [String: MCPProbeRecord] = [:],
        mcpFallbackEstimate: MCPFallbackEstimate? = nil,
        measuredFirstTurnInputsByAgent: [AgentID: Int] = [:]
    ) async throws -> [Budget] {
        var results: [Budget] = []
        for adapter in adapters where adapter.capabilities.contains(.budget) {
            let agent = type(of: adapter).id
            let computed = try await budget(
                for: agent,
                folder: folder,
                model: model,
                tokenizer: tokenizer,
                mcpProbesByConfigHash: mcpProbesByConfigHash,
                mcpFallbackEstimate: mcpFallbackEstimate,
                measuredFirstTurnInput: measuredFirstTurnInputsByAgent[agent]
            )
            results.append(computed)
        }
        return results
    }

    /// Lists all active (`effectiveLoadMode != .never`) MCP server targets resolved in `folder`
    /// for `agentFilter` (or across all budget-capable adapters when `agentFilter == nil`).
    public func resolvedMCPServers(
        for agentFilter: AgentID? = nil,
        folder: URL
    ) async throws -> [ResolvedMCPServerTarget] {
        let candidateAgents: [AgentID]
        if let agentFilter {
            guard let adapter = adaptersByID[agentFilter] else {
                throw BentoScannerError.unknownAgent(agentFilter)
            }
            guard adapter.capabilities.contains(.budget) else {
                throw BentoScannerError.budgetUnsupported(agentFilter)
            }
            candidateAgents = [agentFilter]
        } else {
            candidateAgents =
                adapters
                .filter { $0.capabilities.contains(.budget) }
                .map { type(of: $0).id }
        }

        var targets: [ResolvedMCPServerTarget] = []
        for agent in candidateAgents {
            let (artifacts, resolution) = try await loadArtifactsAndResolution(for: agent, folder: folder)
            let artifactsByID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.id, $0) })
            for resolved in resolution.ordered where resolved.effectiveLoadMode != .never {
                guard let artifact = artifactsByID[resolved.artifactID],
                    case .mcpServer(let config) = artifact.payload
                else {
                    continue
                }
                targets.append(
                    ResolvedMCPServerTarget(
                        agent: agent,
                        artifact: artifact,
                        config: config
                    )
                )
            }
        }
        return targets
    }

    private func loadArtifactsAndResolution(
        for agent: AgentID,
        folder: URL
    ) async throws -> (artifacts: [Artifact], resolution: Resolution) {
        let stdFolder = folder.standardizedFileURL
        if let snapshot = try currentSnapshot(),
            let cachedResolution = snapshot.resolution(for: agent, repoPath: stdFolder.path)
        {
            let canonicalPath = snapshot.resolveCanonicalRepoPath(stdFolder.path)
            let artifacts = snapshot.artifacts(agent: agent, repoPath: canonicalPath)
            return (artifacts, cachedResolution)
        }
        return try await resolveOnDemand(agent: agent, folder: stdFolder)
    }
}
