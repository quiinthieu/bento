import ArgumentParser
import BentoCore
import BentoFixes
import BentoScanner
import BentoStore
import Darwin
import Foundation

/// Plans, previews (dry-run default), and atomically applies reversible configuration fixes (`PLAN.md` §6.6, §6.8).
struct FixCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fix",
        abstract: "Preview or apply a reversible configuration fix (defaults to --dry-run)."
    )

    @OptionGroup var common: CLICommonOptions

    @Argument(
        help:
            "Fix kind (e.g. disableMCPServer, enableMCPServer, disableSkill, enableSkill, consolidateSkillsViaSymlink, replaceDuplicateRulesWithImport, trashArtifact)."
    )
    var kind: String

    @Argument(help: "Target artifact ID, finding ID, artifact name, or path.")
    var target: String

    @Option(name: .long, help: "Target agent identifier when disambiguating by name.")
    var agent: String?

    @Option(name: .long, help: "Target repository folder.")
    var repo: String?

    @Option(
        name: .customLong("target-rules"),
        help: "Shared rules file path to import for replaceDuplicateRulesWithImport (defaults to sibling AGENTS.md)."
    )
    var targetRules: String?

    @Option(
        name: .customLong("canonical-skills-dir"),
        help: "Canonical skills directory for consolidateSkillsViaSymlink (defaults to ~/.agents/skills)."
    )
    var canonicalSkillsDir: String?

    @Flag(name: .customLong("dry-run"), help: "Preview unified diff without modifying any files (default).")
    var dryRun = false

    @Flag(name: .long, help: "Execute the fix atomically with backup and post-state verification.")
    var apply = false

    @Flag(name: .long, help: "Confirm execution without an interactive prompt (required with --apply in non-TTY).")
    var yes = false

    mutating func run() async throws {
        if dryRun && apply {
            throw ValidationError("Cannot combine --dry-run and --apply.")
        }

        let parsedKind = try Self.parseFixKind(kind)
        let parsedAgent = try agent.map { try CLICommonOptions.parseAgent($0) }
        let resolvedRepoURL = repo.map { CLICommonOptions.resolvePath($0) }
        let resolvedTargetRulesPath = targetRules.map { CLICommonOptions.resolvePath($0).path }
        let resolvedCanonicalDir = canonicalSkillsDir.map { CLICommonOptions.resolvePath($0).path }

        // Enforce non-TTY confirmation guard BEFORE opening a writable run or modifying any file.
        let isInteractiveTTY = (isatty(STDIN_FILENO) != 0) && (isatty(STDOUT_FILENO) != 0)
        if apply && !yes && !isInteractiveTTY {
            throw ValidationError(
                BentoFixesError.nonInteractiveConfirmationRequired.localizedDescription
            )
        }

        let (env, store, supportDir) = try common.makeRuntime(requirePersistentStore: apply)
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

        let fixSupports = workspace.allFixSupports()
        let trashHandler: any TrashHandling =
            (common.home != nil)
            ? HermeticTrashHandler(trashDirectory: supportDir.appendingPathComponent("Trash", isDirectory: true))
            : SystemTrashHandler()

        let engine = FixEngine(
            homeURL: env.home,
            supportDirectory: supportDir,
            store: store,
            fileSystem: env.fileSystem,
            trashHandler: trashHandler,
            now: env.now
        )

        let confirmed = yes || (!apply && parsedKind == .trashArtifact)
        let request = try Self.buildFixRequest(
            kind: parsedKind,
            target: target,
            parsedAgent: parsedAgent,
            repoPath: resolvedRepoURL?.path,
            targetRulesPath: resolvedTargetRulesPath,
            canonicalSkillsRoot: resolvedCanonicalDir,
            confirmed: confirmed,
            snapshot: snapshot,
            store: store,
            fixSupports: fixSupports
        )

        let plan = try engine.plan(request, snapshot: snapshot, fixSupports: fixSupports)
        let redactedDiffs = UnifiedDiffGenerator.preview(
            plan: plan,
            fileSystem: env.fileSystem,
            redactSecrets: true
        )
        let persistedSummary = PersistedFixPlanSummary(from: plan)

        guard apply else {
            if common.json {
                let response = CLIJSONOutput.FixResponse(
                    generatedAt: env.now(),
                    snapshotID: snapshot.id,
                    fixID: plan.id,
                    kind: plan.kind,
                    agent: plan.agent.rawValue,
                    summary: plan.summary,
                    applied: false,
                    dryRun: true,
                    backupDir: nil,
                    status: "dry_run",
                    affectedPaths: plan.affectedPaths,
                    operations: persistedSummary.operations,
                    diffs: redactedDiffs
                )
                try CLIJSONOutput.printJSON(response)
            } else {
                Self.printHumanPreview(plan: plan, diffs: redactedDiffs)
            }
            return
        }

        if !yes {
            Self.printHumanPreview(plan: plan, diffs: redactedDiffs, toStandardError: common.json)
            FileHandle.standardError.write(Data("Apply fix '\(plan.summary)'? [y/N]: ".utf8))
            let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard answer == "y" || answer == "yes" else {
                throw ExitCode(1)
            }
        }

        let result = try await engine.apply(plan, allowChanges: true) { appliedPlan in
            let rescan = try await workspace.scanFull()
            // Verify none of the written files introduced a fatal config parse error.
            let affectedSet = Set(appliedPlan.affectedPaths)
            let hasNewSyntaxError = rescan.artifacts.contains { item in
                affectedSet.contains(item.location.path)
                    && item.diagnostics.contains { diag in
                        diag.severity == .error
                            && (diag.code.hasPrefix("json.") || diag.code.hasPrefix("toml."))
                    }
            }
            return !hasNewSyntaxError
        }

        if common.json {
            let response = CLIJSONOutput.FixResponse(
                generatedAt: env.now(),
                snapshotID: snapshot.id,
                fixID: result.fixID,
                kind: plan.kind,
                agent: plan.agent.rawValue,
                summary: plan.summary,
                applied: true,
                dryRun: false,
                backupDir: result.backupDir.path,
                status: result.journalEntry.status.rawValue,
                affectedPaths: plan.affectedPaths,
                operations: persistedSummary.operations,
                diffs: redactedDiffs
            )
            try CLIJSONOutput.printJSON(response)
        } else {
            print("Applied fix \(result.fixID): \(plan.summary)")
            print("Backup saved at: \(result.backupDir.path)")
            print("Undo with: \(Product.cliName) undo \(result.fixID)")
        }
    }

    // MARK: - Helpers

    private static func parseFixKind(_ raw: String) throws -> FixKind {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = FixKind(rawValue: trimmed) {
            return exact
        }
        switch trimmed.lowercased() {
        case "disablemcpserver", "disable-mcp-server", "disable-mcp":
            return .disableMCPServer
        case "enablemcpserver", "enable-mcp-server", "enable-mcp":
            return .enableMCPServer
        case "disableskill", "disable-skill":
            return .disableSkill
        case "enableskill", "enable-skill":
            return .enableSkill
        case "consolidateskillsviasymlink", "consolidate-skills-via-symlink", "consolidate-skills":
            return .consolidateSkillsViaSymlink
        case "replaceduplicateruleswithimport", "replace-duplicate-rules-with-import", "replace-duplicate-rules":
            return .replaceDuplicateRulesWithImport
        case "trashartifact", "trash-artifact", "trash":
            return .trashArtifact
        default:
            let valid = FixKind.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("Unknown fix kind '\(raw)'. Expected one of: \(valid).")
        }
    }

    private static func buildFixRequest(
        kind: FixKind,
        target: String,
        parsedAgent: AgentID?,
        repoPath: String?,
        targetRulesPath: String?,
        canonicalSkillsRoot: String?,
        confirmed: Bool,
        snapshot: Snapshot,
        store: BentoStore,
        fixSupports: [AgentID: FixSupport]
    ) throws -> FixRequest {
        // 1. Exact ArtifactID match
        if let byID = snapshot.artifacts.first(where: { $0.id.rawValue == target }) {
            if kind == .consolidateSkillsViaSymlink {
                let peers = snapshot.artifacts.filter {
                    $0.kind == .skill
                        && $0.name == byID.name
                        && (fixSupports[$0.agent]?.supportedKinds.contains(.consolidateSkillsViaSymlink) == true)
                }
                return FixRequest(
                    kind: kind,
                    artifacts: peers.isEmpty ? [byID] : peers,
                    canonicalSkillsRoot: canonicalSkillsRoot,
                    confirmed: confirmed
                )
            }
            return FixRequest(
                kind: kind,
                artifact: byID,
                targetRulesPath: targetRulesPath,
                canonicalSkillsRoot: canonicalSkillsRoot,
                confirmed: confirmed
            )
        }

        // 2. Persisted Finding ID match
        if let finding = (try? store.fetchFindings(snapshotID: snapshot.id))?.first(where: { $0.id == target }) {
            let byIDMap = Dictionary(uniqueKeysWithValues: snapshot.artifacts.map { ($0.id, $0) })
            let matched = finding.artifacts.compactMap { byIDMap[$0] }
            if kind == .consolidateSkillsViaSymlink {
                let skills = matched.filter { $0.kind == .skill }
                if !skills.isEmpty {
                    return FixRequest(
                        kind: kind,
                        artifacts: skills,
                        canonicalSkillsRoot: canonicalSkillsRoot,
                        confirmed: confirmed
                    )
                }
            } else if kind == .replaceDuplicateRulesWithImport {
                let importable = matched.first { item in
                    item.kind == .rules
                        && URL(fileURLWithPath: item.location.path).lastPathComponent != "AGENTS.md"
                        && (fixSupports[item.agent]?.supportsAtImports == true)
                }
                let sharedAgents = matched.first { item in
                    URL(fileURLWithPath: item.location.path).lastPathComponent == "AGENTS.md"
                }
                if let importable {
                    return FixRequest(
                        kind: kind,
                        artifact: importable,
                        targetRulesPath: targetRulesPath ?? sharedAgents?.location.path,
                        canonicalSkillsRoot: canonicalSkillsRoot,
                        confirmed: confirmed
                    )
                }
            } else if let first = matched.first {
                return FixRequest(
                    kind: kind,
                    artifact: first,
                    targetRulesPath: targetRulesPath,
                    canonicalSkillsRoot: canonicalSkillsRoot,
                    confirmed: confirmed
                )
            }
        }

        // 3. Consolidation by skill name
        if kind == .consolidateSkillsViaSymlink {
            let matchingSkills = snapshot.artifacts.filter { item in
                item.kind == .skill
                    && item.name == target
                    && (parsedAgent == nil || item.agent == parsedAgent)
                    && (fixSupports[item.agent]?.supportedKinds.contains(.consolidateSkillsViaSymlink) == true)
            }
            if !matchingSkills.isEmpty {
                return FixRequest(
                    kind: kind,
                    artifacts: matchingSkills,
                    canonicalSkillsRoot: canonicalSkillsRoot,
                    confirmed: confirmed
                )
            }
        }

        // 4. Path or name match against discovered artifacts
        let resolvedCandidatePath = CLICommonOptions.resolvePath(target).path
        let expectedArtifactKind: ArtifactKind? = {
            switch kind {
            case .disableMCPServer, .enableMCPServer:
                return .mcpServer
            case .disableSkill, .enableSkill, .consolidateSkillsViaSymlink:
                return .skill
            case .replaceDuplicateRulesWithImport:
                return .rules
            case .trashArtifact:
                return nil
            }
        }()

        let artifactMatches = snapshot.artifacts.filter { item in
            if let parsedAgent, item.agent != parsedAgent { return false }
            if let expectedArtifactKind, item.kind != expectedArtifactKind { return false }
            if let repoPath {
                let inRepo =
                    item.location.path == repoPath
                    || item.location.path.hasPrefix(repoPath + "/")
                if !inRepo { return false }
            }
            let itemDir = URL(fileURLWithPath: item.location.path).deletingLastPathComponent().path
            return item.name == target
                || item.location.path == resolvedCandidatePath
                || (item.kind == .skill && itemDir == resolvedCandidatePath)
        }

        if let match = artifactMatches.first {
            return FixRequest(
                kind: kind,
                artifact: match,
                targetRulesPath: targetRulesPath,
                canonicalSkillsRoot: canonicalSkillsRoot,
                confirmed: confirmed
            )
        }

        // 5. Stashed item lookup (enableMCPServer / enableSkill) when not currently in snapshot
        if kind == .enableMCPServer || kind == .enableSkill {
            let fallbackAgent = parsedAgent ?? .claudeCode
            return FixRequest(
                kind: kind,
                agent: fallbackAgent,
                targetName: target,
                repoPath: repoPath,
                targetRulesPath: targetRulesPath,
                canonicalSkillsRoot: canonicalSkillsRoot,
                confirmed: confirmed
            )
        }

        throw ValidationError("No matching target found for '\(target)'.")
    }

    private static func printHumanPreview(
        plan: FixPlan,
        diffs: [UnifiedDiff],
        toStandardError: Bool = false
    ) {
        var lines: [String] = [
            "Fix preview (\(plan.kind.rawValue), agent: \(plan.agent.rawValue)): \(plan.summary)"
        ]
        for diff in diffs {
            lines.append("  * \(diff.summary)")
            if !diff.patch.isEmpty {
                for patchLine in diff.patch.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("    \(patchLine)")
                }
            }
        }
        let output = lines.joined(separator: "\n") + "\n"
        if toStandardError {
            FileHandle.standardError.write(Data(output.utf8))
        } else {
            print(output, terminator: "")
        }
    }
}
