import ArgumentParser
import BentoCore
import BentoScanner
import Foundation

/// Performs a full read-only scan across all supported agents and discovered repositories (`PLAN.md` §6.8).
struct ScanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Discover agents, repositories, artifacts, and resolutions."
    )

    @OptionGroup var common: CLICommonOptions

    mutating func run() async throws {
        let (env, store) = try common.makeRuntime()
        defer { try? store.close() }
        let workspace = Workspace(environment: env, store: store)
        let snapshot = try await workspace.scanFull()

        let allArtifacts = snapshot.artifacts
        var agentCounts: [String: Int] = [:]
        var detectionsByRawID: [String: DetectionResult] = [:]
        for agent in AgentID.allCases {
            agentCounts[agent.rawValue] = allArtifacts.filter { $0.agent == agent }.count
            if let detection = snapshot.detections[agent] {
                detectionsByRawID[agent.rawValue] = detection
            }
        }

        if common.json {
            let response = CLIJSONOutput.ScanResponse(
                generatedAt: env.now(),
                snapshotID: snapshot.id,
                createdAt: snapshot.createdAt,
                scannerVersion: snapshot.scannerVersion,
                homePath: snapshot.homePath,
                homeHash: snapshot.homeHash,
                detections: detectionsByRawID,
                repos: snapshot.repos,
                artifactCount: allArtifacts.count,
                agentCounts: agentCounts,
                resolutionCount: snapshot.resolutions.count
            )
            try CLIJSONOutput.printJSON(response)
            return
        }

        let detectedNames = AgentID.allCases
            .filter { snapshot.detections[$0]?.isDetected == true }
            .map(\.rawValue)
            .joined(separator: ", ")

        print("Snapshot: \(snapshot.id)")
        print("Home: \(snapshot.homePath)")
        print("Detected agents: \(detectedNames.isEmpty ? "none" : detectedNames)")
        print("Discovered repos (\(snapshot.repos.count)):")
        for repo in snapshot.repos {
            print("  - \(repo.displayName) (\(repo.path))")
        }
        print("Artifacts: \(allArtifacts.count) | Resolutions: \(snapshot.resolutions.count)")
    }
}
