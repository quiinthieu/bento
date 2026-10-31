import ArgumentParser
import BentoCore
import BentoScanner
import Foundation

/// Resolves effective artifact load order and shadowing for an agent in a target folder (`PLAN.md` §6.8).
struct ResolveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resolve",
        abstract: "Show ordered artifact resolution and shadowing reasons for a repository and agent."
    )

    @OptionGroup var common: CLICommonOptions

    @Option(name: .long, help: "Target repository or working directory path.")
    var repo: String

    @Option(name: .long, help: "Agent identifier (claudeCode, codex, gemini, copilot, cursor, windsurf).")
    var agent: String

    mutating func run() async throws {
        let parsedAgent = try CLICommonOptions.parseAgent(agent)
        let repoURL = CLICommonOptions.resolvePath(repo)
        let (env, store) = try common.makeRuntime()
        defer { try? store.close() }
        let workspace = Workspace(environment: env, store: store)

        let snapshotID: String
        let canonicalRepoPath: String
        let artifacts: [Artifact]
        let resolution: Resolution

        if let existing = try await workspace.currentSnapshot(),
            let cachedResolution = existing.resolution(for: parsedAgent, repoPath: repoURL.path)
        {
            snapshotID = existing.id
            canonicalRepoPath = existing.resolveCanonicalRepoPath(repoURL.path)
            artifacts = existing.artifacts(agent: parsedAgent, repoPath: canonicalRepoPath)
            resolution = cachedResolution
        } else {
            let onDemand = try await workspace.resolveOnDemand(agent: parsedAgent, folder: repoURL)
            snapshotID = "on-demand-\(UUID().uuidString.lowercased())"
            canonicalRepoPath = repoURL.path
            artifacts = onDemand.artifacts
            resolution = onDemand.resolution
        }

        if common.json {
            let response = CLIJSONOutput.ResolveResponse(
                generatedAt: env.now(),
                snapshotID: snapshotID,
                agent: parsedAgent.rawValue,
                repoPath: canonicalRepoPath,
                artifacts: artifacts,
                resolution: resolution
            )
            try CLIJSONOutput.printJSON(response)
            return
        }

        let byID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.id, $0) })
        print("Resolution: \(parsedAgent.rawValue) @ \(canonicalRepoPath)")
        print("Ordered (\(resolution.ordered.count)):")
        for (idx, item) in resolution.ordered.enumerated() {
            let label = byID[item.artifactID]?.name ?? item.artifactID.rawValue
            print("  \(idx + 1). \(label) — \(item.reason)")
        }
        if !resolution.shadowed.isEmpty {
            print("Shadowed (\(resolution.shadowed.count)):")
            for record in resolution.shadowed {
                let loser = byID[record.shadowedArtifactID]?.name ?? record.shadowedArtifactID.rawValue
                print("  - \(loser): \(record.reason)")
            }
        }
    }
}
