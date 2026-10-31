import ArgumentParser
import BentoCore
import BentoScanner
import Foundation

/// Lists discovered artifacts across global and repository scopes (`PLAN.md` §6.8).
struct InventoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inventory",
        abstract: "List discovered agent configuration artifacts."
    )

    @OptionGroup var common: CLICommonOptions

    @Option(name: .long, help: "Filter inventory to a single agent identifier.")
    var agent: String?

    @Option(name: .long, help: "Filter inventory to artifacts reachable from a repository folder.")
    var repo: String?

    mutating func run() async throws {
        let parsedAgent = try agent.map { try CLICommonOptions.parseAgent($0) }
        let resolvedRepoURL = repo.map { CLICommonOptions.resolvePath($0) }
        let (env, store) = try common.makeRuntime()
        defer { try? store.close() }
        let workspace = Workspace(environment: env, store: store)

        let existing = try await workspace.currentSnapshot()
        let snapshot: Snapshot
        if let existing {
            snapshot = existing
        } else {
            snapshot = try await workspace.scanFull()
        }

        let canonicalRepoPath = resolvedRepoURL.map { snapshot.resolveCanonicalRepoPath($0.path) }
        let artifacts: [Artifact]
        if let repoURL = resolvedRepoURL {
            let cached = snapshot.artifacts(agent: parsedAgent, repoPath: repoURL.path)
            let isKnownRepo = snapshot.repos.contains {
                $0.path == canonicalRepoPath || $0.realPath == repoURL.path
            }
            if isKnownRepo || !cached.isEmpty {
                artifacts = cached
            } else {
                artifacts = try await workspace.discoverOnDemand(agent: parsedAgent, folder: repoURL)
            }
        } else {
            artifacts = snapshot.artifacts(agent: parsedAgent, repoPath: nil)
        }

        if common.json {
            let response = CLIJSONOutput.InventoryResponse(
                generatedAt: env.now(),
                snapshotID: snapshot.id,
                agentFilter: parsedAgent?.rawValue,
                repoFilter: canonicalRepoPath,
                artifacts: artifacts
            )
            try CLIJSONOutput.printJSON(response)
            return
        }

        print("Snapshot: \(snapshot.id) (\(artifacts.count) artifacts)")
        for item in artifacts {
            let status = item.enabled ? "enabled" : "disabled"
            print("[\(item.agent.rawValue)] \(item.kind.rawValue) \(item.name) (\(status)) — \(item.location.path)")
        }
    }
}
