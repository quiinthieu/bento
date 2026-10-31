import BentoCore
import BentoFixes
import Foundation

/// Versioned CLI JSON output envelopes (`Docs/cli-schema.md`, `"schemaVersion": 1`).
enum CLIJSONOutput {
    static let currentSchemaVersion = 1

    struct ScanResponse: Codable, Sendable {
        var schemaVersion: Int = CLIJSONOutput.currentSchemaVersion
        var command: String = "scan"
        var generatedAt: Date
        var snapshotID: String
        var createdAt: Date
        var scannerVersion: String
        var homePath: String
        var homeHash: String
        var detections: [String: DetectionResult]
        var repos: [DiscoveredRepo]
        var artifactCount: Int
        var agentCounts: [String: Int]
        var resolutionCount: Int
    }

    struct InventoryResponse: Codable, Sendable {
        var schemaVersion: Int = CLIJSONOutput.currentSchemaVersion
        var command: String = "inventory"
        var generatedAt: Date
        var snapshotID: String
        var agentFilter: String?
        var repoFilter: String?
        var artifacts: [Artifact]
    }

    struct ResolveResponse: Codable, Sendable {
        var schemaVersion: Int = CLIJSONOutput.currentSchemaVersion
        var command: String = "resolve"
        var generatedAt: Date
        var snapshotID: String
        var agent: String
        var repoPath: String
        var artifacts: [Artifact]
        var resolution: Resolution
    }

    struct BudgetResponse: Codable, Sendable {
        var schemaVersion: Int = CLIJSONOutput.currentSchemaVersion
        var command: String = "budget"
        var generatedAt: Date
        var snapshotID: String
        var repoPath: String
        var agentFilter: String?
        var modelOverride: String?
        var budgets: [Budget]
    }

    struct IngestResponse: Codable, Sendable {
        var schemaVersion: Int = CLIJSONOutput.currentSchemaVersion
        var command: String = "ingest"
        var generatedAt: Date
        var agentFilter: String?
        var didReset: Bool
        var filesDiscovered: Int
        var filesIngested: Int
        var filesSkippedUnchanged: Int
        var bytesRead: Int
        var eventsDecoded: Int
        var eventsInserted: Int
        var sessionsUpdated: Int
        var decoderErrors: Int
        var diagnostics: [Diagnostic]
    }

    struct UsageResponse: Codable, Sendable {
        var schemaVersion: Int = CLIJSONOutput.currentSchemaVersion
        var command: String = "usage"
        var generatedAt: Date
        var days: Int
        var minimumSessions: Int
        var since: Date
        var until: Date
        var agentFilter: String?
        var repoFilter: String?
        var sessionCount: Int
        var eventCount: Int
        var tokenTotals: UsageTokenTotals
        var byAgent: [AgentUsageSummary]
        var artifactUsage: [ArtifactUsageJoin]
        var unusedFindings: [Finding]
    }

    struct HygieneResponse: Codable, Sendable {
        var schemaVersion: Int = CLIJSONOutput.currentSchemaVersion
        var command: String = "hygiene"
        var generatedAt: Date
        var snapshotID: String
        var agentFilter: String?
        var repoFilter: String?
        var failOn: String?
        var findingCount: Int
        var errorCount: Int
        var warningCount: Int
        var infoCount: Int
        var findings: [Finding]
    }

    struct FixResponse: Codable, Sendable {
        var schemaVersion: Int = CLIJSONOutput.currentSchemaVersion
        var command: String = "fix"
        var generatedAt: Date
        var snapshotID: String
        var fixID: String
        var kind: FixKind
        var agent: String
        var summary: String
        var applied: Bool
        var dryRun: Bool
        var backupDir: String?
        var status: String
        var affectedPaths: [String]
        var operations: [PersistedFixPlanSummary.OperationSummary]
        var diffs: [UnifiedDiff]
    }

    struct UndoResponse: Codable, Sendable {
        var schemaVersion: Int = CLIJSONOutput.currentSchemaVersion
        var command: String = "undo"
        var generatedAt: Date
        var fixID: String
        var kind: FixKind
        var backupDir: String
        var status: String
        var undoneAt: Date?
    }

    static func printJSON<T: Encodable>(_ payload: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        print(String(decoding: data, as: UTF8.self))
    }
}
