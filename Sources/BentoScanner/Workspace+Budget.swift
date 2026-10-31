import BentoAdapters
import BentoCore
import Foundation

extension Workspace {
    /// Computes the context token `Budget` for `agent` in `folder`, reusing cached `Snapshot` resolution when available.
    public func budget(
        for agent: AgentID,
        folder: URL,
        model: String? = nil,
        tokenizer: any TokenCountingProvider
    ) async throws -> Budget {
        guard let adapter = adaptersByID[agent] else {
            throw BentoScannerError.unknownAgent(agent)
        }
        guard adapter.capabilities.contains(.budget) else {
            throw BentoScannerError.budgetUnsupported(agent)
        }

        let stdFolder = folder.standardizedFileURL
        let artifacts: [Artifact]
        let resolution: Resolution

        if let snapshot = try currentSnapshot(),
            let cachedResolution = snapshot.resolution(for: agent, repoPath: stdFolder.path)
        {
            let canonicalPath = snapshot.resolveCanonicalRepoPath(stdFolder.path)
            artifacts = snapshot.artifacts(agent: agent, repoPath: canonicalPath)
            resolution = cachedResolution
        } else {
            let onDemand = try await resolveOnDemand(agent: agent, folder: stdFolder)
            artifacts = onDemand.artifacts
            resolution = onDemand.resolution
        }

        return try BudgetEngine().computeBudget(
            adapter: adapter,
            artifacts: artifacts,
            resolution: resolution,
            model: model,
            tokenizer: tokenizer
        )
    }

    /// Computes context token `Budget` breakdowns across all registered budget-capable adapters in `folder`.
    public func budgets(
        folder: URL,
        model: String? = nil,
        tokenizer: any TokenCountingProvider
    ) async throws -> [Budget] {
        var results: [Budget] = []
        for adapter in adapters where adapter.capabilities.contains(.budget) {
            let agent = type(of: adapter).id
            let computed = try await budget(
                for: agent,
                folder: folder,
                model: model,
                tokenizer: tokenizer
            )
            results.append(computed)
        }
        return results
    }
}
