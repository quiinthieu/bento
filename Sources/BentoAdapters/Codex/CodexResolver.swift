import BentoCore
import BentoParsing
import Foundation

/// Precedence, project-trust, `AGENTS.override.md`, and `project_doc_max_bytes` resolver for OpenAI Codex CLI.
enum CodexResolver {
    static func resolve(_ artifacts: [Artifact], folder: URL, env: AgentEnvironment) -> Resolution {
        let targetFolder = folder.standardizedFileURL
        let hierarchy = CodexDiscovery.resolveFolderHierarchy(for: targetFolder, in: env)

        var ordered: [ResolvedArtifact] = []
        var shadowed: [ShadowRecord] = []
        var warnings: [Diagnostic] = []

        // 1. Evaluate effective config policy from discovered settings artifacts
        let settingsArtifacts = artifacts.filter { $0.kind == .settings }
        let userSettingsTree: [String: JSONValue]? = settingsArtifacts.first { $0.scope == .user }.flatMap {
            if case .settings(let doc) = $0.payload { return doc.tree }
            return nil
        }
        let isProjectTrusted = CodexDiscovery.evaluateProjectTrust(
            userTree: userSettingsTree,
            hierarchy: hierarchy,
            in: env
        )

        if !isProjectTrusted,
            artifacts.contains(where: {
                ($0.scope == .project || $0.scope == .directory)
                    && ($0.kind == .settings || $0.kind == .hook || $0.kind == .mcpServer)
            })
        {
            warnings.append(
                Diagnostic(
                    code: "codex.projectUntrusted",
                    severity: .warning,
                    message:
                        "Project '\(hierarchy?.repoRoot.lastPathComponent ?? targetFolder.lastPathComponent)' is marked untrusted; project .codex configurations and hooks are skipped",
                    location: AdapterPathNormalizer.sourceLocation(for: hierarchy?.repoRoot ?? targetFolder, in: env)
                )
            )
        }

        let highToLowSettings = settingsArtifacts.sorted {
            settingsPrecedenceRank(for: $0, targetFolder: targetFolder, env: env)
                < settingsPrecedenceRank(for: $1, targetFolder: targetFolder, env: env)
        }
        var trustedPrecedenceTrees: [[String: JSONValue]] = []
        for item in highToLowSettings {
            if !isProjectTrusted && (item.scope == .project || item.scope == .directory) {
                continue
            }
            if case .settings(let doc) = item.payload {
                trustedPrecedenceTrees.append(doc.tree)
            }
        }
        let summary = CodexDiscovery.buildEffectiveConfigSummary(
            precedenceTrees: trustedPrecedenceTrees,
            isProjectTrusted: isProjectTrusted,
            in: env
        )

        // 2. Settings (base -> override: user -> project -> directory -> managed)
        ordered.append(
            contentsOf: resolveSettings(
                settingsArtifacts,
                isProjectTrusted: isProjectTrusted,
                targetFolder: targetFolder,
                in: env
            )
        )

        // 3. Instruction chain (`AGENTS.override.md` vs `AGENTS.md` + `project_doc_fallback_filenames` + `project_doc_max_bytes`)
        let ruleResults = resolveRules(
            artifacts.filter { $0.kind == .rules },
            summary: summary,
            hierarchy: hierarchy,
            targetFolder: targetFolder,
            in: env
        )
        ordered.append(contentsOf: ruleResults.ordered)
        shadowed.append(contentsOf: ruleResults.shadowed)
        warnings.append(contentsOf: ruleResults.warnings)

        // 4. Exclusive-by-name MCP servers (`managed` > `directory` > `project` > `user`)
        let mcpResults = resolveMCPServers(
            artifacts.filter { $0.kind == .mcpServer },
            isProjectTrusted: isProjectTrusted,
            targetFolder: targetFolder,
            in: env
        )
        ordered.append(contentsOf: mcpResults.ordered)
        shadowed.append(contentsOf: mcpResults.shadowed)

        // 5. Exclusive-by-name Skills (`directory` > `project` [.agents > .codex] > `user` [.agents > .codex] > `builtIn`)
        let skillResults = resolveSkills(
            artifacts.filter { $0.kind == .skill },
            targetFolder: targetFolder,
            in: env
        )
        ordered.append(contentsOf: skillResults.ordered)
        shadowed.append(contentsOf: skillResults.shadowed)

        // 6. Hooks (`allow_managed_hooks_only` & project trust)
        ordered.append(
            contentsOf: resolveHooks(
                artifacts.filter { $0.kind == .hook },
                summary: summary,
                in: env
            )
        )

        return Resolution(
            agent: .codex,
            folder: targetFolder.path,
            ordered: ordered,
            shadowed: shadowed,
            warnings: warnings
        )
    }

    // MARK: - Settings

    private static func resolveSettings(
        _ settingsArtifacts: [Artifact],
        isProjectTrusted: Bool,
        targetFolder: URL,
        in env: AgentEnvironment
    ) -> [ResolvedArtifact] {
        let highToLow = settingsArtifacts.sorted {
            settingsPrecedenceRank(for: $0, targetFolder: targetFolder, env: env)
                < settingsPrecedenceRank(for: $1, targetFolder: targetFolder, env: env)
        }
        let lowToHigh = Array(highToLow.reversed())

        var resolved: [ResolvedArtifact] = []
        for item in lowToHigh {
            let label = CodexPathCatalog.humanSourceLabel(for: item.location.path, scope: item.scope, in: env)
            if !isProjectTrusted && (item.scope == .project || item.scope == .directory) {
                resolved.append(
                    ResolvedArtifact(
                        artifactID: item.id,
                        effectiveLoadMode: .never,
                        reason: "skipped \(label) because project trust_level is untrusted"
                    )
                )
                continue
            }
            guard case .settings = item.payload, item.diagnostics.isEmpty else {
                resolved.append(
                    ResolvedArtifact(
                        artifactID: item.id,
                        effectiveLoadMode: .never,
                        reason: "malformed or unreadable \(label)"
                    )
                )
                continue
            }
            resolved.append(
                ResolvedArtifact(
                    artifactID: item.id,
                    effectiveLoadMode: .never,
                    reason: "merged settings from \(label)"
                )
            )
        }
        return resolved
    }

    // MARK: - Rules (`AGENTS.override.md`, `AGENTS.md`, Fallbacks, `project_doc_max_bytes`)

    private static func resolveRules(
        _ ruleArtifacts: [Artifact],
        summary: CodexDiscovery.EffectiveConfigSummary,
        hierarchy: CodexDiscovery.FolderHierarchy?,
        targetFolder: URL,
        in env: AgentEnvironment
    ) -> (ordered: [ResolvedArtifact], shadowed: [ShadowRecord], warnings: [Diagnostic]) {
        let fs = env.fileSystem
        let candidatePriority = CodexPathCatalog.orderedRuleCandidateFilenames(
            fallbackFilenames: summary.fallbackFilenames
        )

        func filenamePriority(_ artifact: Artifact) -> Int {
            let base = URL(fileURLWithPath: artifact.location.path).lastPathComponent
            return candidatePriority.firstIndex(of: base) ?? (candidatePriority.count + 1)
        }

        func isNonEmptyRule(_ artifact: Artifact) -> Bool {
            guard case .rules(let doc) = artifact.payload else { return false }
            return !doc.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        func ruleByteCount(_ artifact: Artifact) -> Int {
            guard case .rules(let doc) = artifact.payload else { return 0 }
            return doc.byteCount
        }

        // Group discovered rule artifacts by parent directory standardized path
        var byDir: [String: [Artifact]] = [:]
        for item in ruleArtifacts {
            let dirPath = URL(fileURLWithPath: item.location.path)
                .deletingLastPathComponent()
                .standardizedFileURL
                .path
            byDir[dirPath, default: []].append(item)
        }

        let codexHomeDir = CodexPathCatalog.userCodexDirectory(in: env).standardizedFileURL.path
        var activeChainDirs: [String] = [codexHomeDir]
        if let hierarchy {
            let repoDirs = [hierarchy.repoRoot] + hierarchy.ancestorsInsideRepoToTarget
            for dirURL in repoDirs {
                let p = dirURL.standardizedFileURL.path
                if !activeChainDirs.contains(p) {
                    activeChainDirs.append(p)
                }
            }
        } else {
            let p = targetFolder.standardizedFileURL.path
            if !activeChainDirs.contains(p) {
                activeChainDirs.append(p)
            }
        }

        var ordered: [ResolvedArtifact] = []
        var shadowed: [ShadowRecord] = []
        var warnings: [Diagnostic] = []
        var processedDirs: Set<String> = []
        var remainingBytes = max(0, summary.maxBytes)

        // 1. Active directory chain (global $CODEX_HOME -> repoRoot -> ... -> targetFolder)
        for dirPath in activeChainDirs {
            processedDirs.insert(dirPath)
            guard let candidates = byDir[dirPath], !candidates.isEmpty else { continue }
            let sorted = candidates.sorted {
                (filenamePriority($0), $0.id.rawValue) < (filenamePriority($1), $1.id.rawValue)
            }
            let winner = sorted.first(where: { isNonEmptyRule($0) }) ?? sorted[0]
            let winnerLabel = CodexPathCatalog.humanSourceLabel(
                for: winner.location.path,
                scope: winner.scope,
                in: env
            )

            for other in sorted where other.id != winner.id {
                let otherBase = URL(fileURLWithPath: other.location.path).lastPathComponent
                let winBase = URL(fileURLWithPath: winner.location.path).lastPathComponent
                shadowed.append(
                    ShadowRecord(
                        shadowedArtifactID: other.id,
                        winningArtifactID: winner.id,
                        reason: "\(otherBase) overridden by \(winBase) in the same directory (\(winnerLabel))"
                    )
                )
            }

            let bytes = ruleByteCount(winner)
            if summary.maxBytes == 0 || remainingBytes == 0 {
                warnings.append(
                    Diagnostic(
                        code: "rules.truncated",
                        severity: .warning,
                        message:
                            "Skipped '\(winner.name)' because project_doc_max_bytes (\(summary.maxBytes) bytes) was already exhausted",
                        location: winner.location
                    )
                )
                ordered.append(
                    ResolvedArtifact(
                        artifactID: winner.id,
                        effectiveLoadMode: .never,
                        reason:
                            "skipped \(winnerLabel) after project_doc_max_bytes (\(summary.maxBytes) B) budget exhausted"
                    )
                )
            } else if bytes > remainingBytes {
                warnings.append(
                    Diagnostic(
                        code: "rules.truncated",
                        severity: .warning,
                        message:
                            "Truncated '\(winner.name)' (\(bytes) bytes) to fit remaining \(remainingBytes) bytes of project_doc_max_bytes (\(summary.maxBytes) bytes)",
                        location: winner.location
                    )
                )
                remainingBytes = 0
                ordered.append(
                    ResolvedArtifact(
                        artifactID: winner.id,
                        effectiveLoadMode: .always,
                        reason:
                            "loaded from \(winnerLabel), truncated to fit project_doc_max_bytes (\(summary.maxBytes) B)"
                    )
                )
            } else {
                remainingBytes -= bytes
                ordered.append(
                    ResolvedArtifact(
                        artifactID: winner.id,
                        effectiveLoadMode: .always,
                        reason: "loaded in Codex instruction chain from \(winnerLabel)"
                    )
                )
            }
        }

        // 2. Remaining directories (descendants below targetFolder or siblings)
        for dirPath in byDir.keys.sorted() where !processedDirs.contains(dirPath) {
            guard let candidates = byDir[dirPath], !candidates.isEmpty else { continue }
            let sorted = candidates.sorted {
                (filenamePriority($0), $0.id.rawValue) < (filenamePriority($1), $1.id.rawValue)
            }
            let winner = sorted.first(where: { isNonEmptyRule($0) }) ?? sorted[0]
            let winnerLabel = CodexPathCatalog.humanSourceLabel(
                for: winner.location.path,
                scope: winner.scope,
                in: env
            )

            for other in sorted where other.id != winner.id {
                let otherBase = URL(fileURLWithPath: other.location.path).lastPathComponent
                let winBase = URL(fileURLWithPath: winner.location.path).lastPathComponent
                shadowed.append(
                    ShadowRecord(
                        shadowedArtifactID: other.id,
                        winningArtifactID: winner.id,
                        reason: "\(otherBase) overridden by \(winBase) in the same directory (\(winnerLabel))"
                    )
                )
            }

            let dirURL = URL(fileURLWithPath: dirPath, isDirectory: true)
            if let relFromTarget = AdapterPathNormalizer.relativePath(
                of: dirURL,
                from: targetFolder,
                fileSystem: fs
            ), !relFromTarget.isEmpty {
                ordered.append(
                    ResolvedArtifact(
                        artifactID: winner.id,
                        effectiveLoadMode: .conditional(globs: ["\(relFromTarget)/**"]),
                        reason: "nested directory instructions under \(relFromTarget)/ (loaded when launched inside)"
                    )
                )
            } else {
                ordered.append(
                    ResolvedArtifact(
                        artifactID: winner.id,
                        effectiveLoadMode: .never,
                        reason: "outside active folder chain for \(targetFolder.lastPathComponent)"
                    )
                )
            }
        }

        return (ordered, shadowed, warnings)
    }

    // MARK: - MCP Servers

    private static func resolveMCPServers(
        _ mcpArtifacts: [Artifact],
        isProjectTrusted: Bool,
        targetFolder: URL,
        in env: AgentEnvironment
    ) -> (ordered: [ResolvedArtifact], shadowed: [ShadowRecord]) {
        var byName: [String: [Artifact]] = [:]
        for item in mcpArtifacts {
            byName[item.name, default: []].append(item)
        }

        var ordered: [ResolvedArtifact] = []
        var shadowed: [ShadowRecord] = []

        for name in byName.keys.sorted() {
            guard let group = byName[name] else { continue }
            let trustedCandidates = group.filter { item in
                isProjectTrusted || (item.scope != .project && item.scope != .directory)
            }
            let untrustedCandidates = group.filter { item in
                !isProjectTrusted && (item.scope == .project || item.scope == .directory)
            }

            if !trustedCandidates.isEmpty {
                let sorted = trustedCandidates.sorted {
                    mcpPrecedenceRank(for: $0, targetFolder: targetFolder)
                        < mcpPrecedenceRank(for: $1, targetFolder: targetFolder)
                }
                let winner = sorted[0]
                let winnerLabel = CodexPathCatalog.humanSourceLabel(
                    for: winner.location.path,
                    scope: winner.scope,
                    in: env
                )

                for loser in sorted.dropFirst() {
                    let loserLabel = CodexPathCatalog.humanSourceLabel(
                        for: loser.location.path,
                        scope: loser.scope,
                        in: env
                    )
                    shadowed.append(
                        ShadowRecord(
                            shadowedArtifactID: loser.id,
                            winningArtifactID: winner.id,
                            reason: "MCP server '\(name)' in \(loserLabel) overridden by \(winnerLabel)"
                        )
                    )
                }
                for untrusted in untrustedCandidates {
                    let untrustedLabel = CodexPathCatalog.humanSourceLabel(
                        for: untrusted.location.path,
                        scope: untrusted.scope,
                        in: env
                    )
                    shadowed.append(
                        ShadowRecord(
                            shadowedArtifactID: untrusted.id,
                            winningArtifactID: winner.id,
                            reason:
                                "MCP server '\(name)' in untrusted \(untrustedLabel) ignored in favor of \(winnerLabel)"
                        )
                    )
                }

                let isDisabled: Bool =
                    if case .mcpServer(let cfg) = winner.payload {
                        cfg.disabled || !winner.enabled
                    } else {
                        !winner.enabled
                    }

                ordered.append(
                    ResolvedArtifact(
                        artifactID: winner.id,
                        effectiveLoadMode: isDisabled ? .never : .always,
                        reason: isDisabled
                            ? "disabled via enabled = false in \(winnerLabel)"
                            : "active MCP server from \(winnerLabel)"
                    )
                )
            } else {
                // Only untrusted project/directory definitions exist
                let sortedUntrusted = untrustedCandidates.sorted {
                    mcpPrecedenceRank(for: $0, targetFolder: targetFolder)
                        < mcpPrecedenceRank(for: $1, targetFolder: targetFolder)
                }
                let primary = sortedUntrusted[0]
                let primaryLabel = CodexPathCatalog.humanSourceLabel(
                    for: primary.location.path,
                    scope: primary.scope,
                    in: env
                )
                for extra in sortedUntrusted.dropFirst() {
                    shadowed.append(
                        ShadowRecord(
                            shadowedArtifactID: extra.id,
                            winningArtifactID: primary.id,
                            reason: "duplicate untrusted MCP server '\(name)' superseded by \(primaryLabel)"
                        )
                    )
                }
                ordered.append(
                    ResolvedArtifact(
                        artifactID: primary.id,
                        effectiveLoadMode: .never,
                        reason: "skipped MCP server from \(primaryLabel) because project trust_level is untrusted"
                    )
                )
            }
        }

        return (ordered, shadowed)
    }

    // MARK: - Skills

    private static func resolveSkills(
        _ skillArtifacts: [Artifact],
        targetFolder: URL,
        in env: AgentEnvironment
    ) -> (ordered: [ResolvedArtifact], shadowed: [ShadowRecord]) {
        var byName: [String: [Artifact]] = [:]
        for item in skillArtifacts {
            byName[item.name, default: []].append(item)
        }

        var ordered: [ResolvedArtifact] = []
        var shadowed: [ShadowRecord] = []

        for name in byName.keys.sorted() {
            guard let group = byName[name] else { continue }
            let sorted = group.sorted {
                skillPrecedenceRank(for: $0, targetFolder: targetFolder)
                    < skillPrecedenceRank(for: $1, targetFolder: targetFolder)
            }
            let winner = sorted[0]
            let winnerLabel = CodexPathCatalog.humanSourceLabel(
                for: winner.location.path,
                scope: winner.scope,
                in: env
            )

            for loser in sorted.dropFirst() {
                let loserLabel = CodexPathCatalog.humanSourceLabel(
                    for: loser.location.path,
                    scope: loser.scope,
                    in: env
                )
                shadowed.append(
                    ShadowRecord(
                        shadowedArtifactID: loser.id,
                        winningArtifactID: winner.id,
                        reason: "Skill '\(name)' in \(loserLabel) overridden by \(winnerLabel)"
                    )
                )
            }

            ordered.append(
                ResolvedArtifact(
                    artifactID: winner.id,
                    effectiveLoadMode: winner.enabled ? .frontmatterOnly : .never,
                    reason: winner.enabled
                        ? "active skill metadata from \(winnerLabel)"
                        : "disabled via [[skills.config]] for \(winnerLabel)"
                )
            )
        }

        return (ordered, shadowed)
    }

    // MARK: - Hooks

    private static func resolveHooks(
        _ hookArtifacts: [Artifact],
        summary: CodexDiscovery.EffectiveConfigSummary,
        in env: AgentEnvironment
    ) -> [ResolvedArtifact] {
        let sorted = hookArtifacts.sorted {
            ($0.scope.rawValue, $0.name, $0.id.rawValue) < ($1.scope.rawValue, $1.name, $1.id.rawValue)
        }

        return sorted.map { hook in
            let label = CodexPathCatalog.humanSourceLabel(for: hook.location.path, scope: hook.scope, in: env)
            if !summary.isProjectTrusted && (hook.scope == .project || hook.scope == .directory) {
                return ResolvedArtifact(
                    artifactID: hook.id,
                    effectiveLoadMode: .never,
                    reason: "skipped hook from \(label) because project trust_level is untrusted"
                )
            }
            if summary.allowManagedHooksOnly && hook.scope != .managed {
                return ResolvedArtifact(
                    artifactID: hook.id,
                    effectiveLoadMode: .never,
                    reason: "blocked by allow_managed_hooks_only policy"
                )
            }
            guard hook.enabled, case .hook = hook.payload else {
                return ResolvedArtifact(
                    artifactID: hook.id,
                    effectiveLoadMode: .never,
                    reason: "disabled or malformed hook in \(label)"
                )
            }
            return ResolvedArtifact(
                artifactID: hook.id,
                effectiveLoadMode: .onInvoke,
                reason: "active lifecycle hook from \(label)"
            )
        }
    }

    // MARK: - Precedence Ranks (lower = higher priority)

    private static func settingsPrecedenceRank(
        for artifact: Artifact,
        targetFolder: URL,
        env: AgentEnvironment
    ) -> (Int, Int, String) {
        switch artifact.scope {
        case .managed:
            let reqPriority = CodexPathCatalog.isManagedRequirementsPath(artifact.location.path) ? 0 : 1
            return (0, reqPriority, artifact.id.rawValue)
        case .directory:
            let depth = artifact.location.path.split(separator: "/").count
            return (1, -depth, artifact.id.rawValue)
        case .project, .projectLocal:
            return (2, 0, artifact.id.rawValue)
        case .user:
            return (3, 0, artifact.id.rawValue)
        case .builtIn:
            return (4, 0, artifact.id.rawValue)
        }
    }

    private static func mcpPrecedenceRank(
        for artifact: Artifact,
        targetFolder: URL
    ) -> (Int, Int, String) {
        switch artifact.scope {
        case .managed:
            return (0, 0, artifact.id.rawValue)
        case .directory:
            let depth = artifact.location.path.split(separator: "/").count
            return (1, -depth, artifact.id.rawValue)
        case .project, .projectLocal:
            return (2, 0, artifact.id.rawValue)
        case .user:
            let isProfile = (artifact.location.keyPath?.first == "profiles") ? 0 : 1
            return (3, isProfile, artifact.id.rawValue)
        case .builtIn:
            return (4, 0, artifact.id.rawValue)
        }
    }

    private static func skillPrecedenceRank(
        for artifact: Artifact,
        targetFolder: URL
    ) -> (Int, Int, Int, String) {
        let aliasRank = CodexPathCatalog.isAgentsAliasSkillPath(artifact.location.path) ? 0 : 1
        switch artifact.scope {
        case .managed:
            return (0, 0, aliasRank, artifact.id.rawValue)
        case .directory:
            let depth = artifact.location.path.split(separator: "/").count
            return (1, -depth, aliasRank, artifact.id.rawValue)
        case .project, .projectLocal:
            return (2, 0, aliasRank, artifact.id.rawValue)
        case .user:
            return (3, 0, aliasRank, artifact.id.rawValue)
        case .builtIn:
            return (4, 0, aliasRank, artifact.id.rawValue)
        }
    }
}
