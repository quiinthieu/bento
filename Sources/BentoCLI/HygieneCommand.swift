import ArgumentParser
import BentoCore
import BentoHygiene
import BentoScanner
import BentoStore
import BentoTokenizer
import Foundation

/// Audits rules and configuration hygiene across agents and repositories (`PLAN.md` §6.5, §6.8, §11 T13).
struct HygieneCommand: AsyncParsableCommand {
    enum FailOnThreshold: String, ExpressibleByArgument, CaseIterable, Sendable {
        case warning
        case error

        func triggersExitFailure(for findings: [Finding]) -> Bool {
            switch self {
            case .warning:
                return findings.contains { $0.severity == .warning || $0.severity == .error }
            case .error:
                return findings.contains { $0.severity == .error }
            }
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "hygiene",
        abstract: "Audit duplicate rules, directive conflicts, size limits, and broken imports."
    )

    @OptionGroup var common: CLICommonOptions

    @Option(name: .long, help: "Filter hygiene audit to a repository folder.")
    var repo: String?

    @Option(name: .long, help: "Filter hygiene audit to a single agent identifier.")
    var agent: String?

    @Option(
        name: .customLong("fail-on"),
        help: "Exit with status 1 when any finding reaches the given severity (warning or error)."
    )
    var failOn: FailOnThreshold?

    @Option(
        name: .customLong("max-rule-tokens"),
        help: "Maximum token threshold for a single always-on rules file (default: 10000)."
    )
    var maxRuleTokens: Int = HygieneConfig.defaultMaxAlwaysOnRuleTokens

    mutating func run() async throws {
        guard maxRuleTokens > 0 else {
            throw ValidationError("--max-rule-tokens must be greater than 0.")
        }
        let parsedAgent = try agent.map { try CLICommonOptions.parseAgent($0) }
        let resolvedRepoURL = repo.map { CLICommonOptions.resolvePath($0) }
        let (env, store) = try common.makeRuntime()
        defer { try? store.close() }

        let discoveryOptions = RepoDiscoveryOptions(
            manualPaths: resolvedRepoURL.map { [$0] } ?? []
        )
        let workspace = Workspace(
            environment: env,
            store: store,
            repoDiscoveryOptions: discoveryOptions
        )

        let existing = try await workspace.currentSnapshot()
        let snapshot: Snapshot
        if let existing {
            snapshot = existing
        } else {
            snapshot = try await workspace.scanFull()
        }

        let tokenizer = try AgentTokenizerRegistry()
        let hygieneConfig = HygieneConfig(maxAlwaysOnRuleTokens: maxRuleTokens)
        let engine = HygieneEngine(config: hygieneConfig)
        let fixSupports = workspace.allFixSupports()

        let canonicalRepoFilter: String?
        let findings: [Finding]

        if let repoURL = resolvedRepoURL {
            let resolvedCanonical = snapshot.resolveCanonicalRepoPath(repoURL.path)
            canonicalRepoFilter = resolvedCanonical
            let isKnownInSnapshot = snapshot.repos.contains {
                $0.path == resolvedCanonical || $0.realPath == repoURL.path
            }

            if isKnownInSnapshot {
                findings = try engine.audit(
                    snapshot: snapshot,
                    fixSupports: fixSupports,
                    fileSystem: env.fileSystem,
                    tokenizer: tokenizer,
                    agentFilter: parsedAgent,
                    repoFilter: resolvedCanonical
                )
            } else {
                let onDemand = try await workspace.discoverAndResolveOnDemand(
                    agentFilter: nil,
                    folder: repoURL
                )
                let allFindings = try engine.audit(
                    artifacts: onDemand.artifacts,
                    resolutions: onDemand.resolutions,
                    repos: snapshot.repos + [onDemand.repo],
                    homePath: snapshot.homePath,
                    fixSupports: fixSupports,
                    fileSystem: env.fileSystem,
                    tokenizer: tokenizer
                )
                if let parsedAgent {
                    let agentIDs = Set(onDemand.artifacts.lazy.filter { $0.agent == parsedAgent }.map(\.id))
                    findings = allFindings.filter { finding in
                        finding.artifacts.contains { agentIDs.contains($0) }
                    }
                } else {
                    findings = allFindings
                }
            }
        } else {
            canonicalRepoFilter = nil
            findings = try engine.audit(
                snapshot: snapshot,
                fixSupports: fixSupports,
                fileSystem: env.fileSystem,
                tokenizer: tokenizer,
                agentFilter: parsedAgent,
                repoFilter: nil
            )
        }

        // Persist hygiene findings into BentoStore without clobbering `unused` usage-join findings.
        if canonicalRepoFilter == nil && parsedAgent == nil {
            let hygieneKinds: [Finding.Kind] = [
                .exactDuplicate,
                .nearDuplicate,
                .conflict,
                .sizeLimit,
                .brokenImport,
                .invalidConfig
            ]
            for kind in hygieneKinds {
                let subset = findings.filter { $0.kind == kind }
                try store.saveFindings(subset, snapshotID: snapshot.id, replacingKind: kind)
            }
        } else if !findings.isEmpty {
            try store.saveFindings(findings, snapshotID: snapshot.id)
        }

        let errorCount = findings.filter { $0.severity == .error }.count
        let warningCount = findings.filter { $0.severity == .warning }.count
        let infoCount = findings.filter { $0.severity == .info }.count

        if common.json {
            let response = CLIJSONOutput.HygieneResponse(
                generatedAt: env.now(),
                snapshotID: snapshot.id,
                agentFilter: parsedAgent?.rawValue,
                repoFilter: canonicalRepoFilter,
                failOn: failOn?.rawValue,
                findingCount: findings.count,
                errorCount: errorCount,
                warningCount: warningCount,
                infoCount: infoCount,
                findings: findings
            )
            try CLIJSONOutput.printJSON(response)
        } else {
            print(
                "Hygiene audit (\(findings.count) finding(s): "
                    + "\(errorCount) error, \(warningCount) warning, \(infoCount) info)"
            )
            for finding in findings {
                print("  [\(finding.severity.rawValue)] (\(finding.kind.rawValue)) \(finding.message)")
                for span in finding.spans {
                    if let range = span.lineRange {
                        print("    -> \(span.path):\(range.lowerBound)-\(range.upperBound)")
                    } else {
                        print("    -> \(span.path)")
                    }
                }
            }
        }

        if let failOn, failOn.triggersExitFailure(for: findings) {
            throw ExitCode(1)
        }
    }
}
