import ArgumentParser
import BentoCore
import BentoStore
import Foundation

/// Shared CLI flags and environment/store bootstrap helpers across subcommands (`PLAN.md` §6.8).
struct CLICommonOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "Target home directory to inspect read-only (uses in-memory store unless --db is set)."
    )
    var home: String?

    @Option(
        name: .long,
        help: "Explicit SQLite store path to share snapshots across invocations."
    )
    var db: String?

    @Flag(
        name: .long,
        help: "Emit machine-readable JSON output conforming to Docs/cli-schema.md."
    )
    var json = false

    /// Builds an isolated `AgentEnvironment` and matching `BentoStore` without touching real `$HOME` when `--home` is supplied.
    func makeRuntime(requirePersistentStore: Bool = false) throws -> (
        environment: AgentEnvironment,
        store: BentoStore,
        supportDirectory: URL
    ) {
        let processEnv = ProcessInfo.processInfo.environment
        let homeURL: URL
        if let rawHome = home?.trimmingCharacters(in: .whitespacesAndNewlines), !rawHome.isEmpty {
            homeURL = Self.resolvePath(rawHome, processEnv: processEnv)
        } else if let envHome = processEnv["HOME"], !envHome.isEmpty {
            homeURL = URL(fileURLWithPath: envHome, isDirectory: true).standardizedFileURL
        } else {
            throw ValidationError("Unable to determine target home directory; pass --home <PATH>.")
        }

        let effectiveEnv: [String: String]
        if home != nil {
            effectiveEnv = processEnv.filter { $0.key.hasPrefix("BENTO_") }
        } else {
            effectiveEnv = processEnv
        }

        let fixedNow: Date?
        if let rawNow = processEnv["BENTO_NOW_ISO8601"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawNow.isEmpty
        {
            fixedNow = ISO8601DateFormatter().date(from: rawNow)
        } else {
            fixedNow = nil
        }

        let agentEnv = AgentEnvironment(
            home: homeURL,
            env: effectiveEnv,
            fileSystem: LocalReadOnlyFileSystem(),
            now: { fixedNow ?? Date() }
        )

        let explicitDB = db?.trimmingCharacters(in: .whitespacesAndNewlines) ?? processEnv["BENTO_DB_PATH"]
        let store: BentoStore
        let supportDir: URL
        if let explicitDB, !explicitDB.isEmpty {
            let dbURL = Self.resolvePath(explicitDB, processEnv: processEnv)
            store = try BentoStore(databaseURL: dbURL)
            supportDir = dbURL.deletingLastPathComponent().standardizedFileURL
        } else if home != nil && !requirePersistentStore {
            store = try BentoStore.inMemory()
            supportDir = BentoStore.defaultDatabaseURL(home: homeURL).deletingLastPathComponent()
        } else {
            let defaultDB = BentoStore.defaultDatabaseURL(home: homeURL)
            store = try BentoStore(databaseURL: defaultDB)
            supportDir = defaultDB.deletingLastPathComponent().standardizedFileURL
        }

        return (agentEnv, store, supportDir)
    }

    /// Backwards-compatible 2-tuple overload for read-only subcommands.
    func makeRuntime() throws -> (environment: AgentEnvironment, store: BentoStore) {
        let (env, store, _) = try makeRuntime(requirePersistentStore: false)
        return (env, store)
    }

    /// Resolves a CLI path argument against the current working directory without expanding tilde via Foundation's real-HOME APIs.
    static func resolvePath(_ raw: String, processEnv: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw).standardizedFileURL
        }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent(raw)
            .standardizedFileURL
    }

    /// Parses canonical `AgentID` raw values (`claudeCode`, `codex`, ...) plus kebab-case aliases (`claude-code`, `claude`).
    static func parseAgent(_ raw: String) throws -> AgentID {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = AgentID(rawValue: trimmed) {
            return exact
        }
        switch trimmed.lowercased() {
        case "claudecode", "claude-code", "claude_code", "claude":
            return .claudeCode
        case "codex", "codex-cli":
            return .codex
        case "gemini", "gemini-cli":
            return .gemini
        case "copilot", "copilot-cli", "github-copilot":
            return .copilot
        case "cursor":
            return .cursor
        case "windsurf":
            return .windsurf
        default:
            let valid = AgentID.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("Unknown agent '\(raw)'. Expected one of: \(valid).")
        }
    }
}
