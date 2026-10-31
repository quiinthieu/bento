import BentoAdapters
import BentoCore
import Foundation

extension Workspace {
    /// Discovers session log sources and per-file `LogDecoder` factories for `agent` (or all `.usageLogs` adapters).
    public func logIngestTargets(for agent: AgentID? = nil) throws -> [LogIngestTarget] {
        let selectedAdapters: [any AgentAdapter]
        if let agent {
            guard let adapter = adaptersByID[agent] else {
                throw BentoScannerError.unknownAgent(agent)
            }
            selectedAdapters = adapter.capabilities.contains(.usageLogs) ? [adapter] : []
        } else {
            selectedAdapters = adapters.filter { $0.capabilities.contains(.usageLogs) }
        }

        var targets: [LogIngestTarget] = []
        for adapter in selectedAdapters {
            let sources = try adapter.logSources(in: environment)
            for source in sources {
                targets.append(
                    LogIngestTarget(source: source) {
                        adapter.makeLogDecoder()
                    }
                )
            }
        }
        return targets
    }

    /// Discovers known workspace repositories using the environment and pinned repo options without running a full scan.
    public func discoverRepositories() -> [DiscoveredRepo] {
        RepoDiscovery.discover(in: environment, options: effectiveRepoDiscoveryOptions())
    }
}
