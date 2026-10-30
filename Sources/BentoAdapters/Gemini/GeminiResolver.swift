import BentoCore
import BentoParsing
import Foundation

/// Precedence, 4-tier settings merge, `context.fileName` hierarchy, MCP `excluded`/`allowed` policy,
/// `.agents/skills` alias priority, and extension shadowing resolver for Google Gemini CLI.
enum GeminiResolver {
    static func resolve(_ artifacts: [Artifact], folder: URL, env: AgentEnvironment) -> Resolution {
        let targetFolder = folder.standardizedFileURL
        let hierarchy = GeminiDiscovery.resolveFolderHierarchy(for: targetFolder, in: env)

        var ordered: [ResolvedArtifact] = []
        var shadowed: [ShadowRecord] = []
        let warnings: [Diagnostic] = []

        // 1. Settings (base -> override: builtIn -> user -> project -> managed)
        let settingsArtifacts = artifacts.filter { $0.kind == .settings }
        let highToLowSettings = settingsArtifacts.sorted {
            settingsPrecedenceRank(for: $0) < settingsPrecedenceRank(for: $1)
        }
        let precedenceTrees: [[String: JSONValue]] = highToLowSettings.compactMap { item in
            guard case .settings(let doc) = item.payload else { return nil }
            return doc.tree
        }
        let summary = GeminiDiscovery.buildEffectiveSettingsSummary(precedenceTrees: precedenceTrees)

        ordered.append(contentsOf: resolveSettings(settingsArtifacts, in: env))

        // 2. Installed Extensions (`.plugin`) & Ignore Files (`.ignoreFile`)
        let pluginArtifacts =
            artifacts
            .filter { $0.kind == .plugin }
            .sorted { ($0.name, $0.id.rawValue) < ($1.name, $1.id.rawValue) }
        for plugin in pluginArtifacts {
            let reason =
                plugin.enabled
                ? "enabled Gemini CLI extension (\(plugin.name))"
                : "disabled Gemini CLI extension (\(plugin.name))"
            ordered.append(
                ResolvedArtifact(
                    artifactID: plugin.id,
                    effectiveLoadMode: .never,
                    reason: reason
                )
            )
        }

        let ignoreArtifacts =
            artifacts
            .filter { $0.kind == .ignoreFile }
            .sorted { $0.id.rawValue < $1.id.rawValue }
        for ignoreItem in ignoreArtifacts {
            let label = GeminiPathCatalog.humanSourceLabel(
                for: ignoreItem.location.path,
                scope: ignoreItem.scope,
                in: env
            )
            ordered.append(
                ResolvedArtifact(
                    artifactID: ignoreItem.id,
                    effectiveLoadMode: .never,
                    reason: "active file exclusion rules from \(label)"
                )
            )
        }

        // 3. Context / Rules Hierarchy (concatenation across user -> repo -> ancestors -> extensions, + JIT descendants)
        ordered.append(
            contentsOf: resolveRules(
                artifacts.filter { $0.kind == .rules },
                hierarchy: hierarchy,
                targetFolder: targetFolder,
                in: env
            )
        )

        // 4. Exclusive-by-name MCP Servers (`managed` > `project` > `user` > `builtIn` > `extension`)
        let mcpResults = resolveMCPServers(
            artifacts.filter { $0.kind == .mcpServer },
            summary: summary,
            in: env
        )
        ordered.append(contentsOf: mcpResults.ordered)
        shadowed.append(contentsOf: mcpResults.shadowed)

        // 5. Exclusive-by-name Skills (`project` [.agents > .gemini] > `user` [.agents > .gemini] > `extension`)
        let skillResults = resolveSkills(
            artifacts.filter { $0.kind == .skill },
            in: env
        )
        ordered.append(contentsOf: skillResults.ordered)
        shadowed.append(contentsOf: skillResults.shadowed)

        // 6. Exclusive-by-name Subagents (`project` > `user` > `extension`)
        let subagentResults = resolveSubagents(
            artifacts.filter { $0.kind == .subagent },
            summary: summary,
            in: env
        )
        ordered.append(contentsOf: subagentResults.ordered)
        shadowed.append(contentsOf: subagentResults.shadowed)

        // 7. Exclusive-by-name Commands (`project` > `user` > `extension`)
        let commandResults = resolveCommands(
            artifacts.filter { $0.kind == .command },
            in: env
        )
        ordered.append(contentsOf: commandResults.ordered)
        shadowed.append(contentsOf: commandResults.shadowed)

        // 8. Hooks
        ordered.append(
            contentsOf: resolveHooks(
                artifacts.filter { $0.kind == .hook },
                in: env
            )
        )

        return Resolution(
            agent: .gemini,
            folder: targetFolder.path,
            ordered: ordered,
            shadowed: shadowed,
            warnings: warnings
        )
    }

    // MARK: - Settings

    private static func resolveSettings(
        _ settingsArtifacts: [Artifact],
        in env: AgentEnvironment
    ) -> [ResolvedArtifact] {
        let highToLow = settingsArtifacts.sorted {
            settingsPrecedenceRank(for: $0) < settingsPrecedenceRank(for: $1)
        }
        let lowToHigh = Array(highToLow.reversed())

        var keysByID: [ArtifactID: Set<String>] = [:]
        for item in highToLow {
            if case .settings(let doc) = item.payload {
                keysByID[item.id] = Set(doc.tree.keys).subtracting(["hooks"])
            } else {
                keysByID[item.id] = []
            }
        }

        var resolved: [ResolvedArtifact] = []
        for item in lowToHigh {
            let label = GeminiPathCatalog.humanSourceLabel(
                for: item.location.path,
                scope: item.scope,
                in: env
            )
            guard item.enabled, case .settings = item.payload, item.diagnostics.isEmpty else {
                resolved.append(
                    ResolvedArtifact(
                        artifactID: item.id,
                        effectiveLoadMode: .never,
                        reason: "malformed or unreadable \(label)"
                    )
                )
                continue
            }

            let ownRank = settingsPrecedenceRank(for: item)
            var higherKeys: Set<String> = []
            for higher in highToLow where settingsPrecedenceRank(for: higher) < ownRank {
                higherKeys.formUnion(keysByID[higher.id] ?? [])
            }

            let overridden = (keysByID[item.id] ?? []).intersection(higherKeys).sorted()
            let reason: String
            if item.scope == .managed {
                reason = "merged system override settings from \(label) (highest precedence)"
            } else if !overridden.isEmpty {
                reason =
                    "merged settings from \(label); keys [\(overridden.joined(separator: ", "))] overridden by higher-precedence tier"
            } else {
                reason = "merged settings from \(label)"
            }

            resolved.append(
                ResolvedArtifact(
                    artifactID: item.id,
                    effectiveLoadMode: .never,
                    reason: reason
                )
            )
        }
        return resolved
    }

    // MARK: - Context / Rules Hierarchy

    private static func resolveRules(
        _ ruleArtifacts: [Artifact],
        hierarchy: GeminiDiscovery.FolderHierarchy?,
        targetFolder: URL,
        in env: AgentEnvironment
    ) -> [ResolvedArtifact] {
        let fs = env.fileSystem
        let userGeminiPath = GeminiPathCatalog.userGeminiDirectory(in: env).standardizedFileURL.path

        var activeWorkspaceDirs: [String] = []
        if let hierarchy {
            let dirs = hierarchy.ancestorsAboveRepo + [hierarchy.repoRoot] + hierarchy.ancestorsInsideRepoToTarget
            for dir in dirs {
                let p = dir.standardizedFileURL.path
                if !activeWorkspaceDirs.contains(p) {
                    activeWorkspaceDirs.append(p)
                }
            }
        } else {
            activeWorkspaceDirs.append(targetFolder.standardizedFileURL.path)
        }

        var userRules: [ResolvedArtifact] = []
        var workspaceActiveByDir: [String: [ResolvedArtifact]] = [:]
        var extensionRules: [ResolvedArtifact] = []
        var descendantRules: [(sortKey: String, resolved: ResolvedArtifact)] = []

        for rule in ruleArtifacts {
            let label = GeminiPathCatalog.humanSourceLabel(
                for: rule.location.path,
                scope: rule.scope,
                in: env
            )

            guard case .rules = rule.payload else {
                userRules.append(
                    ResolvedArtifact(
                        artifactID: rule.id,
                        effectiveLoadMode: .never,
                        reason: "unreadable or invalid context file \(label)"
                    )
                )
                continue
            }

            if GeminiPathCatalog.isExtensionArtifactPath(rule.location.path, in: env) {
                extensionRules.append(
                    ResolvedArtifact(
                        artifactID: rule.id,
                        effectiveLoadMode: rule.enabled ? .always : .never,
                        reason: rule.enabled
                            ? "concatenated extension context from \(label)"
                            : "skipped context from disabled \(label)"
                    )
                )
                continue
            }

            let ruleURL = URL(fileURLWithPath: rule.location.path).standardizedFileURL
            if rule.scope == .user
                || ruleURL.path == userGeminiPath
                || ruleURL.path.hasPrefix(userGeminiPath + "/")
            {
                userRules.append(
                    ResolvedArtifact(
                        artifactID: rule.id,
                        effectiveLoadMode: rule.enabled ? .always : .never,
                        reason: "concatenated global user context from \(label)"
                    )
                )
                continue
            }

            let parentDirURL = ruleURL.deletingLastPathComponent().standardizedFileURL
            let parentDirPath = parentDirURL.path

            if let matchingChainDir = activeWorkspaceDirs.first(where: { dirPath in
                parentDirPath == dirPath
            }) {
                workspaceActiveByDir[matchingChainDir, default: []].append(
                    ResolvedArtifact(
                        artifactID: rule.id,
                        effectiveLoadMode: rule.enabled ? .always : .never,
                        reason: "concatenated workspace context from \(label)"
                    )
                )
            } else if let relFromTarget = AdapterPathNormalizer.relativePath(
                of: parentDirURL,
                from: targetFolder,
                fileSystem: fs
            ), !relFromTarget.isEmpty {
                let identityKey = AdapterPathNormalizer.canonicalIdentityPath(for: ruleURL, in: env)
                descendantRules.append(
                    (
                        sortKey: identityKey,
                        resolved: ResolvedArtifact(
                            artifactID: rule.id,
                            effectiveLoadMode: .conditional(globs: ["\(relFromTarget)/**"]),
                            reason:
                                "JIT subdirectory context under \(relFromTarget)/ (loaded when accessing files inside)"
                        )
                    )
                )
            } else if let activeChainRoot = activeWorkspaceDirs.first,
                parentDirPath.hasPrefix(activeChainRoot + "/")
            {
                // Imported Markdown file inside a subdirectory (e.g. docs/style.md imported by repo GEMINI.md)
                // or sibling directory rule when resolving from a deeper subfolder.
                let isConditionalRule: Bool =
                    switch rule.loadMode {
                    case .conditional:
                        true
                    case .always, .frontmatterOnly, .onInvoke, .deferred, .never:
                        false
                    }
                let identityKey = AdapterPathNormalizer.canonicalIdentityPath(for: ruleURL, in: env)
                if isConditionalRule {
                    descendantRules.append(
                        (
                            sortKey: identityKey,
                            resolved: ResolvedArtifact(
                                artifactID: rule.id,
                                effectiveLoadMode: .never,
                                reason: "outside active folder hierarchy for \(targetFolder.lastPathComponent)"
                            )
                        )
                    )
                } else {
                    workspaceActiveByDir[activeChainRoot, default: []].append(
                        ResolvedArtifact(
                            artifactID: rule.id,
                            effectiveLoadMode: rule.enabled ? .always : .never,
                            reason: "imported workspace context from \(label)"
                        )
                    )
                }
            } else {
                let identityKey = AdapterPathNormalizer.canonicalIdentityPath(for: ruleURL, in: env)
                descendantRules.append(
                    (
                        sortKey: identityKey,
                        resolved: ResolvedArtifact(
                            artifactID: rule.id,
                            effectiveLoadMode: .never,
                            reason: "outside active folder hierarchy for \(targetFolder.lastPathComponent)"
                        )
                    )
                )
            }
        }

        var ordered: [ResolvedArtifact] = []
        ordered.append(contentsOf: userRules)
        for dirPath in activeWorkspaceDirs {
            if let items = workspaceActiveByDir[dirPath] {
                ordered.append(contentsOf: items)
            }
        }
        ordered.append(contentsOf: extensionRules)
        ordered.append(
            contentsOf: descendantRules.sorted { $0.sortKey < $1.sortKey }.map(\.resolved)
        )
        return ordered
    }

    // MARK: - MCP Servers

    private static func resolveMCPServers(
        _ mcpArtifacts: [Artifact],
        summary: GeminiDiscovery.EffectiveSettingsSummary,
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
            let sorted = group.sorted {
                mcpPrecedenceRank(for: $0, in: env) < mcpPrecedenceRank(for: $1, in: env)
            }
            let winner = sorted[0]
            let winnerLabel = GeminiPathCatalog.humanSourceLabel(
                for: winner.location.path,
                scope: winner.scope,
                in: env
            )

            for loser in sorted.dropFirst() {
                let loserLabel = GeminiPathCatalog.humanSourceLabel(
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

            let isServerDisabled: Bool =
                if case .mcpServer(let cfg) = winner.payload {
                    cfg.disabled || !winner.enabled
                } else {
                    !winner.enabled
                }

            if isServerDisabled {
                ordered.append(
                    ResolvedArtifact(
                        artifactID: winner.id,
                        effectiveLoadMode: .never,
                        reason: "disabled MCP server in \(winnerLabel)"
                    )
                )
            } else if summary.mcpExcluded.contains(name) {
                ordered.append(
                    ResolvedArtifact(
                        artifactID: winner.id,
                        effectiveLoadMode: .never,
                        reason: "excluded by mcp.excluded setting (\(winnerLabel))"
                    )
                )
            } else if let allowed = summary.mcpAllowed, !allowed.contains(name) {
                ordered.append(
                    ResolvedArtifact(
                        artifactID: winner.id,
                        effectiveLoadMode: .never,
                        reason: "not listed in active mcp.allowed setting (\(winnerLabel))"
                    )
                )
            } else {
                ordered.append(
                    ResolvedArtifact(
                        artifactID: winner.id,
                        effectiveLoadMode: .always,
                        reason: "active MCP server from \(winnerLabel)"
                    )
                )
            }
        }

        return (ordered, shadowed)
    }

    // MARK: - Skills

    private static func resolveSkills(
        _ skillArtifacts: [Artifact],
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
                skillPrecedenceRank(for: $0, in: env) < skillPrecedenceRank(for: $1, in: env)
            }
            let winner = sorted[0]
            let winnerLabel = GeminiPathCatalog.humanSourceLabel(
                for: winner.location.path,
                scope: winner.scope,
                in: env
            )

            for loser in sorted.dropFirst() {
                let loserLabel = GeminiPathCatalog.humanSourceLabel(
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
                        : "disabled skill in \(winnerLabel)"
                )
            )
        }

        return (ordered, shadowed)
    }

    // MARK: - Subagents

    private static func resolveSubagents(
        _ subagentArtifacts: [Artifact],
        summary: GeminiDiscovery.EffectiveSettingsSummary,
        in env: AgentEnvironment
    ) -> (ordered: [ResolvedArtifact], shadowed: [ShadowRecord]) {
        var byName: [String: [Artifact]] = [:]
        for item in subagentArtifacts {
            byName[item.name, default: []].append(item)
        }

        var ordered: [ResolvedArtifact] = []
        var shadowed: [ShadowRecord] = []

        for name in byName.keys.sorted() {
            guard let group = byName[name] else { continue }
            let sorted = group.sorted {
                extensionAwarePrecedenceRank(for: $0, in: env)
                    < extensionAwarePrecedenceRank(for: $1, in: env)
            }
            let winner = sorted[0]
            let winnerLabel = GeminiPathCatalog.humanSourceLabel(
                for: winner.location.path,
                scope: winner.scope,
                in: env
            )

            for loser in sorted.dropFirst() {
                let loserLabel = GeminiPathCatalog.humanSourceLabel(
                    for: loser.location.path,
                    scope: loser.scope,
                    in: env
                )
                shadowed.append(
                    ShadowRecord(
                        shadowedArtifactID: loser.id,
                        winningArtifactID: winner.id,
                        reason: "Subagent '\(name)' in \(loserLabel) overridden by \(winnerLabel)"
                    )
                )
            }

            let isActive = winner.enabled && !summary.disabledSubagents.contains(name)
            ordered.append(
                ResolvedArtifact(
                    artifactID: winner.id,
                    effectiveLoadMode: isActive ? .frontmatterOnly : .never,
                    reason: isActive
                        ? "active subagent from \(winnerLabel)"
                        : "disabled subagent in \(winnerLabel)"
                )
            )
        }

        return (ordered, shadowed)
    }

    // MARK: - Commands

    private static func resolveCommands(
        _ commandArtifacts: [Artifact],
        in env: AgentEnvironment
    ) -> (ordered: [ResolvedArtifact], shadowed: [ShadowRecord]) {
        var byName: [String: [Artifact]] = [:]
        for item in commandArtifacts {
            byName[item.name, default: []].append(item)
        }

        var ordered: [ResolvedArtifact] = []
        var shadowed: [ShadowRecord] = []

        for name in byName.keys.sorted() {
            guard let group = byName[name] else { continue }
            let sorted = group.sorted {
                extensionAwarePrecedenceRank(for: $0, in: env)
                    < extensionAwarePrecedenceRank(for: $1, in: env)
            }
            let winner = sorted[0]
            let winnerLabel = GeminiPathCatalog.humanSourceLabel(
                for: winner.location.path,
                scope: winner.scope,
                in: env
            )

            for loser in sorted.dropFirst() {
                let loserLabel = GeminiPathCatalog.humanSourceLabel(
                    for: loser.location.path,
                    scope: loser.scope,
                    in: env
                )
                shadowed.append(
                    ShadowRecord(
                        shadowedArtifactID: loser.id,
                        winningArtifactID: winner.id,
                        reason: "Command '\(name)' in \(loserLabel) overridden by \(winnerLabel)"
                    )
                )
            }

            let isValid = winner.enabled && winner.diagnostics.allSatisfy { $0.severity != .error }
            ordered.append(
                ResolvedArtifact(
                    artifactID: winner.id,
                    effectiveLoadMode: isValid ? .onInvoke : .never,
                    reason: isValid
                        ? "active slash command from \(winnerLabel)"
                        : "disabled or malformed command in \(winnerLabel)"
                )
            )
        }

        return (ordered, shadowed)
    }

    // MARK: - Hooks

    private static func resolveHooks(
        _ hookArtifacts: [Artifact],
        in env: AgentEnvironment
    ) -> [ResolvedArtifact] {
        let sorted = hookArtifacts.sorted {
            ($0.scope.rawValue, $0.name, $0.id.rawValue) < ($1.scope.rawValue, $1.name, $1.id.rawValue)
        }

        return sorted.map { hook in
            let label = GeminiPathCatalog.humanSourceLabel(for: hook.location.path, scope: hook.scope, in: env)
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

    /// Settings precedence: `managed` (`0`) > `project` (`1`) > `user` (`2`) > `builtIn` (`3`).
    private static func settingsPrecedenceRank(for artifact: Artifact) -> (Int, String) {
        switch artifact.scope {
        case .managed:
            return (0, artifact.id.rawValue)
        case .directory:
            return (1, artifact.id.rawValue)
        case .project, .projectLocal:
            return (2, artifact.id.rawValue)
        case .user:
            return (3, artifact.id.rawValue)
        case .builtIn:
            return (4, artifact.id.rawValue)
        }
    }

    /// MCP precedence: `managed` (`0`) > `directory` (`1`) > `project` (`2`) > `user` (`3`) > `builtIn` (`4`) > `extension` (`5`).
    /// Per Gemini CLI specification, any `settings.json` tier (including `system-defaults.json`) outranks extension `mcpServers`.
    private static func mcpPrecedenceRank(
        for artifact: Artifact,
        in env: AgentEnvironment
    ) -> (Int, String) {
        if GeminiPathCatalog.isExtensionArtifactPath(artifact.location.path, in: env) {
            return (5, artifact.id.rawValue)
        }
        switch artifact.scope {
        case .managed:
            return (0, artifact.id.rawValue)
        case .directory:
            return (1, artifact.id.rawValue)
        case .project, .projectLocal:
            return (2, artifact.id.rawValue)
        case .user:
            return (3, artifact.id.rawValue)
        case .builtIn:
            return (4, artifact.id.rawValue)
        }
    }

    /// Skill precedence: `project` (`.agents` > `.gemini`) > `user` (`.agents` > `.gemini`) > `extension`.
    private static func skillPrecedenceRank(
        for artifact: Artifact,
        in env: AgentEnvironment
    ) -> (Int, Int, String) {
        if GeminiPathCatalog.isExtensionArtifactPath(artifact.location.path, in: env) {
            return (5, 0, artifact.id.rawValue)
        }
        let aliasRank = GeminiPathCatalog.isAgentsAliasSkillPath(artifact.location.path) ? 0 : 1
        switch artifact.scope {
        case .managed:
            return (0, aliasRank, artifact.id.rawValue)
        case .directory:
            return (1, aliasRank, artifact.id.rawValue)
        case .project, .projectLocal:
            return (2, aliasRank, artifact.id.rawValue)
        case .user:
            return (3, aliasRank, artifact.id.rawValue)
        case .builtIn:
            return (4, aliasRank, artifact.id.rawValue)
        }
    }

    /// Subagent & command precedence: `project` > `user` > `extension`.
    private static func extensionAwarePrecedenceRank(
        for artifact: Artifact,
        in env: AgentEnvironment
    ) -> (Int, String) {
        if GeminiPathCatalog.isExtensionArtifactPath(artifact.location.path, in: env) {
            return (5, artifact.id.rawValue)
        }
        switch artifact.scope {
        case .managed:
            return (0, artifact.id.rawValue)
        case .directory:
            return (1, artifact.id.rawValue)
        case .project, .projectLocal:
            return (2, artifact.id.rawValue)
        case .user:
            return (3, artifact.id.rawValue)
        case .builtIn:
            return (4, artifact.id.rawValue)
        }
    }
}
