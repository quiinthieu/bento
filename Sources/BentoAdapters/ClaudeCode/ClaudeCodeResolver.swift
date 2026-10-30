import BentoCore
import BentoParsing
import Foundation

/// Precedence, shadowing, and `.mcp.json` trust-gate resolver for Claude Code.
enum ClaudeCodeResolver {
    private struct EffectivePolicy {
        var disabledMcpjsonSources: [String: String] = [:]
        var enabledMcpjsonSources: [String: String] = [:]
        var enableAllProjectMcp: Bool?
        var enableAllProjectMcpSource: String?
        var deniedMCPServers: Set<String> = []
        var allowedMCPServers: Set<String>?
        var disableAllHooks: Bool = false
    }

    static func resolve(_ artifacts: [Artifact], folder: URL, env: AgentEnvironment) -> Resolution {
        let targetFolder = folder.standardizedFileURL
        let hierarchy = ClaudeCodeDiscovery.resolveFolderHierarchy(for: targetFolder, in: env)

        var ordered: [ResolvedArtifact] = []
        var shadowed: [ShadowRecord] = []
        var warnings: [Diagnostic] = []

        // 1. Settings (ordered base -> override: user -> project -> projectLocal -> managed)
        let settingsArtifacts = artifacts.filter { $0.kind == .settings }
        let policy = buildEffectivePolicy(
            from: settingsArtifacts,
            hierarchy: hierarchy,
            targetFolder: targetFolder,
            in: env
        )
        ordered.append(contentsOf: resolveSettings(settingsArtifacts, in: env))

        // 2. Plugins
        let pluginArtifacts =
            artifacts
            .filter { $0.kind == .plugin }
            .sorted { ($0.name, $0.id.rawValue) < ($1.name, $1.id.rawValue) }
        for plugin in pluginArtifacts {
            let reason =
                plugin.enabled
                ? "enabled plugin manifest (\(plugin.name))"
                : "disabled via enabledPlugins setting"
            ordered.append(
                ResolvedArtifact(
                    artifactID: plugin.id,
                    effectiveLoadMode: .never,
                    reason: reason
                )
            )
        }

        // 3. Memory & Rules (concatenation order)
        let ruleArtifacts = artifacts.filter { $0.kind == .rules }
        ordered.append(
            contentsOf: resolveRules(
                ruleArtifacts,
                hierarchy: hierarchy,
                targetFolder: targetFolder,
                in: env
            )
        )

        // 4. Exclusive-by-name kinds: MCP servers, skills, subagents, commands
        let mcpResults = resolveExclusiveGroup(
            artifacts.filter { $0.kind == .mcpServer },
            kindLabel: "MCP server",
            policy: policy,
            in: env
        )
        ordered.append(contentsOf: mcpResults.ordered)
        shadowed.append(contentsOf: mcpResults.shadowed)
        warnings.append(contentsOf: mcpResults.warnings)

        let skillResults = resolveExclusiveGroup(
            artifacts.filter { $0.kind == .skill },
            kindLabel: "Skill",
            policy: policy,
            in: env
        )
        ordered.append(contentsOf: skillResults.ordered)
        shadowed.append(contentsOf: skillResults.shadowed)

        let subagentResults = resolveExclusiveGroup(
            artifacts.filter { $0.kind == .subagent },
            kindLabel: "Subagent",
            policy: policy,
            in: env
        )
        ordered.append(contentsOf: subagentResults.ordered)
        shadowed.append(contentsOf: subagentResults.shadowed)

        let commandResults = resolveExclusiveGroup(
            artifacts.filter { $0.kind == .command },
            kindLabel: "Command",
            policy: policy,
            in: env
        )
        ordered.append(contentsOf: commandResults.ordered)
        shadowed.append(contentsOf: commandResults.shadowed)

        // 5. Hooks
        let hookArtifacts = artifacts.filter { $0.kind == .hook }
        ordered.append(contentsOf: resolveHooks(hookArtifacts, policy: policy, in: env))

        return Resolution(
            agent: .claudeCode,
            folder: targetFolder.path,
            ordered: ordered,
            shadowed: shadowed,
            warnings: warnings
        )
    }

    // MARK: - Settings & Policy

    private static func resolveSettings(
        _ settingsArtifacts: [Artifact],
        in env: AgentEnvironment
    ) -> [ResolvedArtifact] {
        // Precedence rank: managed (0) > projectLocal (1) > project (2) > user (4)
        let highToLow = settingsArtifacts.sorted {
            precedenceRank(for: $0, in: env) < precedenceRank(for: $1, in: env)
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
            let sourceLabel = ClaudeCodePathCatalog.humanSourceLabel(
                for: item.location.path,
                scope: item.scope,
                in: env
            )
            guard item.enabled, case .settings = item.payload else {
                resolved.append(
                    ResolvedArtifact(
                        artifactID: item.id,
                        effectiveLoadMode: .never,
                        reason: "malformed or unreadable \(sourceLabel)"
                    )
                )
                continue
            }

            let ownRank = precedenceRank(for: item, in: env)
            var higherKeys: Set<String> = []
            for higher in highToLow where precedenceRank(for: higher, in: env) < ownRank {
                higherKeys.formUnion(keysByID[higher.id] ?? [])
            }

            let overridden = (keysByID[item.id] ?? []).intersection(higherKeys).sorted()
            let reason: String
            if item.scope == .managed {
                reason = "\(sourceLabel) (highest precedence)"
            } else if !overridden.isEmpty {
                reason =
                    "\(sourceLabel); keys [\(overridden.joined(separator: ", "))] overridden by higher-precedence settings"
            } else {
                reason = "\(sourceLabel)"
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

    private static func buildEffectivePolicy(
        from settingsArtifacts: [Artifact],
        hierarchy: ClaudeCodeDiscovery.FolderHierarchy?,
        targetFolder: URL,
        in env: AgentEnvironment
    ) -> EffectivePolicy {
        var policy = EffectivePolicy()

        let highToLow = settingsArtifacts.sorted {
            precedenceRank(for: $0, in: env) < precedenceRank(for: $1, in: env)
        }

        var disableHooksResolved = false

        for item in highToLow {
            guard item.enabled, case .settings(let doc) = item.payload else {
                continue
            }
            let tree = doc.tree
            let sourceLabel = ClaudeCodePathCatalog.humanSourceLabel(
                for: item.location.path,
                scope: item.scope,
                in: env
            )

            // Enterprise managed MCP allow/deny lists
            if item.scope == .managed {
                policy.deniedMCPServers.formUnion(extractManagedServerNames(from: tree["deniedMcpServers"]))
                if tree["allowedMcpServers"] != nil {
                    policy.allowedMCPServers = extractManagedServerNames(from: tree["allowedMcpServers"])
                }
            }

            // disableAllHooks: highest-precedence explicit bool wins
            if !disableHooksResolved, let flag = ClaudeCodePayloadParser.boolValue(tree["disableAllHooks"]) {
                policy.disableAllHooks = flag
                disableHooksResolved = true
            }

            // disabledMcpjsonServers applies from all active settings tiers (deny wins)
            if let disabledList = ClaudeCodePayloadParser.stringArray(tree["disabledMcpjsonServers"]) {
                for server in disabledList where policy.disabledMcpjsonSources[server] == nil {
                    policy.disabledMcpjsonSources[server] = sourceLabel
                }
            }

            // Trusted tiers for .mcp.json approval: managed, projectLocal (.claude/settings.local.json), and user.
            // Shared project settings (<repo>/.claude/settings.json) CANNOT self-approve untrusted .mcp.json servers.
            let isTrustedForMCPApproval =
                item.scope == .managed
                || ClaudeCodePathCatalog.isProjectLocalSettingsArtifact(item)
                || (item.scope == .user && !ClaudeCodePathCatalog.isPluginSourcedArtifact(item, in: env))

            if isTrustedForMCPApproval {
                if let enabledList = ClaudeCodePayloadParser.stringArray(tree["enabledMcpjsonServers"]) {
                    for server in enabledList where policy.enabledMcpjsonSources[server] == nil {
                        policy.enabledMcpjsonSources[server] = sourceLabel
                    }
                }
                if policy.enableAllProjectMcp == nil,
                    let enableAll = ClaudeCodePayloadParser.boolValue(tree["enableAllProjectMcpServers"])
                {
                    policy.enableAllProjectMcp = enableAll
                    policy.enableAllProjectMcpSource = sourceLabel
                }
            }
        }

        // Also inspect ~/.claude.json projects[<repo>] for project-local enabledMcpjsonServers / disabledMcpjsonServers.
        mergeUserStateProjectApprovals(
            into: &policy,
            hierarchy: hierarchy,
            targetFolder: targetFolder,
            in: env
        )

        return policy
    }

    private static func mergeUserStateProjectApprovals(
        into policy: inout EffectivePolicy,
        hierarchy: ClaudeCodeDiscovery.FolderHierarchy?,
        targetFolder: URL,
        in env: AgentEnvironment
    ) {
        let stateURL = ClaudeCodePathCatalog.userStateFile(in: env)
        guard AdapterPathNormalizer.isEffectiveFile(stateURL, fileSystem: env.fileSystem),
            let rawData = try? env.fileSystem.contents(at: stateURL),
            let tree = try? JSONCParser.parseObject(rawData),
            case .object(let projectsMap) = tree["projects"]
        else {
            return
        }

        let candidateDirs: [URL]
        if let hierarchy {
            candidateDirs = [hierarchy.repoRoot] + hierarchy.ancestorsInsideRepoToTarget
        } else {
            candidateDirs = [targetFolder]
        }

        let candidatePaths = Set(
            candidateDirs.map { $0.standardizedFileURL.path }
                + candidateDirs.map { env.fileSystem.resolveSymlinks($0).standardizedFileURL.path }
        )

        let stateLabel = ClaudeCodePathCatalog.humanSourceLabel(
            for: stateURL.path,
            scope: .projectLocal,
            in: env
        )

        for rawKey in projectsMap.keys.sorted() {
            let expanded = AdapterPathNormalizer.expandHomePrefix(rawKey, in: env)
            let stdPath = expanded.standardizedFileURL.path
            let realPath = env.fileSystem.resolveSymlinks(expanded).standardizedFileURL.path
            guard candidatePaths.contains(stdPath) || candidatePaths.contains(realPath),
                case .object(let projectObj) = projectsMap[rawKey]
            else {
                continue
            }

            if let disabled = ClaudeCodePayloadParser.stringArray(projectObj["disabledMcpjsonServers"]) {
                for server in disabled where policy.disabledMcpjsonSources[server] == nil {
                    policy.disabledMcpjsonSources[server] = stateLabel
                }
            }
            if let enabled = ClaudeCodePayloadParser.stringArray(projectObj["enabledMcpjsonServers"]) {
                for server in enabled where policy.enabledMcpjsonSources[server] == nil {
                    policy.enabledMcpjsonSources[server] = stateLabel
                }
            }
        }
    }

    private static func extractManagedServerNames(from value: JSONValue?) -> Set<String> {
        guard case .array(let items) = value else { return [] }
        var names: Set<String> = []
        for item in items {
            switch item {
            case .string(let str) where !str.isEmpty:
                names.insert(str)
            case .object(let dict):
                if let name = ClaudeCodePayloadParser.nonEmptyString(dict["serverName"])
                    ?? ClaudeCodePayloadParser.nonEmptyString(dict["name"])
                {
                    names.insert(name)
                }
            default:
                break
            }
        }
        return names
    }

    // MARK: - Memory & Rules Resolution

    private static func resolveRules(
        _ rules: [Artifact],
        hierarchy: ClaudeCodeDiscovery.FolderHierarchy?,
        targetFolder: URL,
        in env: AgentEnvironment
    ) -> [ResolvedArtifact] {
        let fs = env.fileSystem
        let repoRoot = hierarchy?.repoRoot ?? targetFolder

        var managedRules: [ResolvedArtifact] = []
        var userMemoryRules: [ResolvedArtifact] = []
        var userModularRules: [(String, ResolvedArtifact)] = []
        var aboveRepoRules: [(Int, ResolvedArtifact)] = []
        var projectMemoryRules: [ResolvedArtifact] = []
        var projectLocalMemoryRules: [ResolvedArtifact] = []
        var projectModularRules: [(String, ResolvedArtifact)] = []
        var ancestorInRepoRules: [(Int, String, ResolvedArtifact)] = []
        var descendantRules: [(String, ResolvedArtifact)] = []

        for rule in rules {
            let effectiveBaseMode: LoadMode = rule.enabled ? rule.loadMode : .never
            switch rule.scope {
            case .managed:
                managedRules.append(
                    ResolvedArtifact(
                        artifactID: rule.id,
                        effectiveLoadMode: effectiveBaseMode,
                        reason: "enterprise managed memory"
                    )
                )
            case .user:
                if ClaudeCodePathCatalog.isModularRulesDirectoryArtifact(rule) {
                    userModularRules.append(
                        (
                            rule.location.path,
                            ResolvedArtifact(
                                artifactID: rule.id,
                                effectiveLoadMode: effectiveBaseMode,
                                reason: modularRuleReason(for: rule, scopeLabel: "user")
                            )
                        ))
                } else {
                    userMemoryRules.append(
                        ResolvedArtifact(
                            artifactID: rule.id,
                            effectiveLoadMode: effectiveBaseMode,
                            reason: "user global memory"
                        )
                    )
                }
            case .project:
                if ClaudeCodePathCatalog.isModularRulesDirectoryArtifact(rule) {
                    projectModularRules.append(
                        (
                            rule.location.path,
                            ResolvedArtifact(
                                artifactID: rule.id,
                                effectiveLoadMode: effectiveBaseMode,
                                reason: modularRuleReason(for: rule, scopeLabel: "project")
                            )
                        ))
                } else {
                    projectMemoryRules.append(
                        ResolvedArtifact(
                            artifactID: rule.id,
                            effectiveLoadMode: effectiveBaseMode,
                            reason: "project shared memory"
                        )
                    )
                }
            case .projectLocal:
                projectLocalMemoryRules.append(
                    ResolvedArtifact(
                        artifactID: rule.id,
                        effectiveLoadMode: effectiveBaseMode,
                        reason: "project-local personal memory"
                    )
                )
            case .directory:
                let ruleFileURL = URL(fileURLWithPath: rule.location.path).standardizedFileURL
                let ruleDir = ruleFileURL.deletingLastPathComponent().standardizedFileURL

                // Check whether ruleDir is above repoRoot
                if AdapterPathNormalizer.relativePath(of: repoRoot, from: ruleDir, fileSystem: fs) != nil,
                    ruleDir.path != repoRoot.path
                {
                    let depth = ruleDir.pathComponents.count
                    aboveRepoRules.append(
                        (
                            depth,
                            ResolvedArtifact(
                                artifactID: rule.id,
                                effectiveLoadMode: rule.enabled ? .always : .never,
                                reason: "ancestor directory memory above repository root"
                            )
                        ))
                } else if AdapterPathNormalizer.relativePath(of: targetFolder, from: ruleDir, fileSystem: fs) != nil {
                    // Ancestor-or-self of targetFolder inside repoRoot -> loaded unconditionally at startup!
                    let depth = ruleDir.pathComponents.count
                    ancestorInRepoRules.append(
                        (
                            depth,
                            rule.location.path,
                            ResolvedArtifact(
                                artifactID: rule.id,
                                effectiveLoadMode: rule.enabled ? .always : .never,
                                reason: "directory memory in working folder hierarchy loaded at startup"
                            )
                        ))
                } else if let relDown = AdapterPathNormalizer.relativePath(
                    of: ruleDir,
                    from: targetFolder,
                    fileSystem: fs
                ), !relDown.isEmpty {
                    // Strictly below targetFolder -> loaded on demand when accessing files under relDown/**
                    let mode: LoadMode = rule.enabled ? .conditional(globs: ["\(relDown)/**"]) : .never
                    descendantRules.append(
                        (
                            "\(relDown)/\(ruleFileURL.lastPathComponent)",
                            ResolvedArtifact(
                                artifactID: rule.id,
                                effectiveLoadMode: mode,
                                reason: "child directory memory loaded on demand for \(relDown)/**"
                            )
                        ))
                }
            case .builtIn:
                break
            }
        }

        var result: [ResolvedArtifact] = []
        result.append(contentsOf: managedRules)
        result.append(contentsOf: userMemoryRules)
        result.append(contentsOf: userModularRules.sorted { $0.0 < $1.0 }.map(\.1))
        result.append(contentsOf: aboveRepoRules.sorted { $0.0 < $1.0 }.map(\.1))
        result.append(contentsOf: projectMemoryRules)
        result.append(contentsOf: projectLocalMemoryRules)
        result.append(contentsOf: projectModularRules.sorted { $0.0 < $1.0 }.map(\.1))
        result.append(contentsOf: ancestorInRepoRules.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2))
        result.append(contentsOf: descendantRules.sorted { $0.0 < $1.0 }.map(\.1))
        return result
    }

    private static func modularRuleReason(for rule: Artifact, scopeLabel: String) -> String {
        if case .conditional(let globs) = rule.loadMode {
            return "\(scopeLabel) modular rule scoped to paths [\(globs.joined(separator: ", "))]"
        }
        return "\(scopeLabel) modular rule"
    }

    // MARK: - Exclusive-by-Name Resolution (MCP, Skills, Subagents, Commands)

    private static func resolveExclusiveGroup(
        _ candidates: [Artifact],
        kindLabel: String,
        policy: EffectivePolicy,
        in env: AgentEnvironment
    ) -> (ordered: [ResolvedArtifact], shadowed: [ShadowRecord], warnings: [Diagnostic]) {
        var grouped: [String: [Artifact]] = [:]
        for item in candidates {
            grouped[item.name, default: []].append(item)
        }

        var ordered: [ResolvedArtifact] = []
        var shadowed: [ShadowRecord] = []
        var warnings: [Diagnostic] = []

        for name in grouped.keys.sorted() {
            guard let items = grouped[name], !items.isEmpty else { continue }
            let ranked = items.sorted { lhs, rhs in
                let lRank = precedenceRank(for: lhs, in: env)
                let rRank = precedenceRank(for: rhs, in: env)
                if lRank != rRank {
                    return lRank < rRank
                }
                if lhs.enabled != rhs.enabled {
                    return lhs.enabled && !rhs.enabled
                }
                return lhs.location.path < rhs.location.path
            }

            let winner = ranked[0]
            let winnerSource = ClaudeCodePathCatalog.humanSourceLabel(
                for: winner.location.path,
                scope: winner.scope,
                in: env
            )

            for loser in ranked.dropFirst() {
                let loserSource = ClaudeCodePathCatalog.humanSourceLabel(
                    for: loser.location.path,
                    scope: loser.scope,
                    in: env
                )
                shadowed.append(
                    ShadowRecord(
                        shadowedArtifactID: loser.id,
                        winningArtifactID: winner.id,
                        reason: "\(kindLabel) '\(name)' in \(loserSource) is shadowed by \(winnerSource)"
                    )
                )
            }

            if winner.kind == .mcpServer {
                let (resolvedMCP, warning) = resolveWinningMCPServer(
                    winner,
                    winnerSource: winnerSource,
                    policy: policy,
                    in: env
                )
                ordered.append(resolvedMCP)
                if let warning {
                    warnings.append(warning)
                }
            } else {
                let effectiveMode: LoadMode = winner.enabled ? winner.loadMode : .never
                let reason =
                    winner.enabled
                    ? "active \(kindLabel.lowercased()) from \(winnerSource)"
                    : "disabled \(kindLabel.lowercased()) from \(winnerSource)"
                ordered.append(
                    ResolvedArtifact(
                        artifactID: winner.id,
                        effectiveLoadMode: effectiveMode,
                        reason: reason
                    )
                )
            }
        }

        return (ordered, shadowed, warnings)
    }

    private static func resolveWinningMCPServer(
        _ server: Artifact,
        winnerSource: String,
        policy: EffectivePolicy,
        in env: AgentEnvironment
    ) -> (ResolvedArtifact, Diagnostic?) {
        if case .other = server.payload {
            return (
                ResolvedArtifact(
                    artifactID: server.id,
                    effectiveLoadMode: .never,
                    reason: "invalid MCP configuration in \(winnerSource)"
                ),
                nil
            )
        }

        if !server.enabled {
            return (
                ResolvedArtifact(
                    artifactID: server.id,
                    effectiveLoadMode: .never,
                    reason: "disabled in \(winnerSource)"
                ),
                nil
            )
        }

        if server.scope != .managed {
            if policy.deniedMCPServers.contains(server.name) {
                return (
                    ResolvedArtifact(
                        artifactID: server.id,
                        effectiveLoadMode: .never,
                        reason: "\(winnerSource); blocked by managed deniedMcpServers"
                    ),
                    nil
                )
            }
            if let allowed = policy.allowedMCPServers, !allowed.contains(server.name) {
                return (
                    ResolvedArtifact(
                        artifactID: server.id,
                        effectiveLoadMode: .never,
                        reason: "\(winnerSource); blocked because not in managed allowedMcpServers"
                    ),
                    nil
                )
            }
        }

        if ClaudeCodePathCatalog.isProjectMCPJsonArtifact(server, in: env) {
            if let disabler = policy.disabledMcpjsonSources[server.name] {
                return (
                    ResolvedArtifact(
                        artifactID: server.id,
                        effectiveLoadMode: .never,
                        reason: "\(winnerSource), disabled via disabledMcpjsonServers in \(disabler)"
                    ),
                    nil
                )
            }
            if let approver = policy.enabledMcpjsonSources[server.name] {
                return (
                    ResolvedArtifact(
                        artifactID: server.id,
                        effectiveLoadMode: server.loadMode,
                        reason: "\(winnerSource), approved in \(approver)"
                    ),
                    nil
                )
            }
            if policy.enableAllProjectMcp == true, let allApprover = policy.enableAllProjectMcpSource {
                return (
                    ResolvedArtifact(
                        artifactID: server.id,
                        effectiveLoadMode: server.loadMode,
                        reason: "\(winnerSource), approved via enableAllProjectMcpServers in \(allApprover)"
                    ),
                    nil
                )
            }

            let diag = Diagnostic(
                code: "mcp.unapproved",
                severity: .warning,
                message: "Project MCP server '\(server.name)' is not approved in local or user settings",
                location: server.location
            )
            return (
                ResolvedArtifact(
                    artifactID: server.id,
                    effectiveLoadMode: .never,
                    reason: "\(winnerSource), pending approval (not in enabledMcpjsonServers)"
                ),
                diag
            )
        }

        return (
            ResolvedArtifact(
                artifactID: server.id,
                effectiveLoadMode: server.loadMode,
                reason: "active MCP server from \(winnerSource)"
            ),
            nil
        )
    }

    // MARK: - Hooks Resolution

    private static func resolveHooks(
        _ hooks: [Artifact],
        policy: EffectivePolicy,
        in env: AgentEnvironment
    ) -> [ResolvedArtifact] {
        let sortedHooks = hooks.sorted { lhs, rhs in
            let lRank = precedenceRank(for: lhs, in: env)
            let rRank = precedenceRank(for: rhs, in: env)
            if lRank != rRank { return lRank < rRank }
            return (lhs.name, lhs.id.rawValue) < (rhs.name, rhs.id.rawValue)
        }

        return sortedHooks.map { hook in
            let sourceLabel = ClaudeCodePathCatalog.humanSourceLabel(
                for: hook.location.path,
                scope: hook.scope,
                in: env
            )
            if case .other = hook.payload {
                return ResolvedArtifact(
                    artifactID: hook.id,
                    effectiveLoadMode: .never,
                    reason: "invalid hook definition in \(sourceLabel)"
                )
            }
            if !hook.enabled {
                return ResolvedArtifact(
                    artifactID: hook.id,
                    effectiveLoadMode: .never,
                    reason: "disabled hook from \(sourceLabel)"
                )
            }
            if policy.disableAllHooks {
                return ResolvedArtifact(
                    artifactID: hook.id,
                    effectiveLoadMode: .never,
                    reason: "disabled by disableAllHooks setting"
                )
            }
            return ResolvedArtifact(
                artifactID: hook.id,
                effectiveLoadMode: .onInvoke,
                reason: "lifecycle hook from \(sourceLabel)"
            )
        }
    }

    // MARK: - Precedence Rank

    private static func precedenceRank(for artifact: Artifact, in env: AgentEnvironment) -> Int {
        switch artifact.scope {
        case .managed:
            return 0
        case .projectLocal:
            return 1
        case .project:
            return 2
        case .directory:
            return 3
        case .user:
            return ClaudeCodePathCatalog.isPluginSourcedArtifact(artifact, in: env) ? 5 : 4
        case .builtIn:
            return 6
        }
    }
}
