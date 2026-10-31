import ArgumentParser
import BentoCore
import BentoLogIngest
import BentoScanner
import BentoStore
import Foundation

/// Incrementally ingests local agent session logs (`.jsonl`, `.json`, `.jsonl.zst`) into `BentoStore`
/// (`PLAN.md` §6.2, §6.8, §11 T11).
struct IngestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ingest",
        abstract: "Incrementally ingest local agent session logs into the usage store."
    )

    @OptionGroup var common: CLICommonOptions

    @Option(name: .long, help: "Optional agent identifier (claudeCode, codex, gemini, copilot).")
    var agent: String?

    @Flag(name: .long, help: "Reset saved log offsets, sessions, and usage events before re-ingesting.")
    var reset = false

    mutating func run() async throws {
        let parsedAgent = try agent.map { try CLICommonOptions.parseAgent($0) }
        let (env, store) = try common.makeRuntime()
        defer { try? store.close() }

        if reset {
            try store.resetLogIngestState()
        }

        let workspace = Workspace(environment: env, store: store)
        let repos = await workspace.discoverRepositories()
        try store.syncDiscoveredRepos(repos, seenAt: env.now())

        let targets = try await workspace.logIngestTargets(for: parsedAgent)
        let ingestor = LogIngestor(fileSystem: env.fileSystem, store: store)
        let report = try await ingestor.ingest(targets: targets)

        if common.json {
            let response = CLIJSONOutput.IngestResponse(
                generatedAt: env.now(),
                agentFilter: parsedAgent?.rawValue,
                didReset: reset,
                filesDiscovered: report.filesDiscovered,
                filesIngested: report.filesIngested,
                filesSkippedUnchanged: report.filesSkippedUnchanged,
                bytesRead: report.bytesRead,
                eventsDecoded: report.eventsDecoded,
                eventsInserted: report.eventsInserted,
                sessionsUpdated: report.sessionsUpdated,
                decoderErrors: report.decoderErrors,
                diagnostics: report.diagnostics
            )
            try CLIJSONOutput.printJSON(response)
            return
        }

        if reset {
            print("Reset previous log ingest cursors and usage events.")
        }
        print(
            "Files discovered: \(report.filesDiscovered) | Ingested: \(report.filesIngested) | "
                + "Unchanged: \(report.filesSkippedUnchanged)"
        )
        print(
            "Events inserted: \(report.eventsInserted) (decoded: \(report.eventsDecoded)) | "
                + "Sessions updated: \(report.sessionsUpdated) | Bytes read: \(report.bytesRead)"
        )
        if report.decoderErrors > 0 {
            print("Skipped malformed lines: \(report.decoderErrors)")
        }
        for diagnostic in report.diagnostics {
            print("  [\(diagnostic.severity.rawValue)] \(diagnostic.code): \(diagnostic.message)")
        }
    }
}
