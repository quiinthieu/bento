import BentoCore
import Foundation

/// Precedence and shadowing resolver for GitHub Copilot CLI (`Docs/adapters/copilot.md`).
enum CopilotResolver {
    static func resolve(_ artifacts: [Artifact], folder: URL, env: AgentEnvironment) -> Resolution {
        let stdFolder = folder.standardizedFileURL
        let hierarchy = CopilotDiscovery.resolveFolderHierarchy(for: stdFolder, in: env)
        let repoRoot = hierarchy?.repoRoot ?? stdFolder

        var ordered: [ResolvedArtifact] = []
        var shadowed: [ShadowRecord] = []
        var warnings: [Diagnostic] = []

        for artifact in artifacts {
            warnings.append(contentsOf: artifact.diagnostics)
        }

        // 1. Settings (`config.json` -> `settings.json`)
        let settingsArtifacts = artifacts.filter { $0.kind == .settings }
            .sorted { $0.location.path < $1.location.path }
        for item in settingsArtifacts {
            ordered.append(
                ResolvedArtifact(
                    artifactID: item.id,
                    effectiveLoadMode: .never,
                    reason: "Copilot CLI user configuration (\(item.name))"
                )
            )
        }

        // 2. Rules (concatenate across scopes without shadowing)
        ordered.append(
            contentsOf: resolveRules(
                artifacts.filter { $0.kind == .rules }, repoRoot: repoRoot, folder: stdFolder, env: env))

        // 3. MCP servers (`.github/mcp.json` > `.vscode/mcp.json` > `~/.copilot/mcp-config.json`)
        let mcpOutcome = resolveMCPServers(artifacts.filter { $0.kind == .mcpServer })
        ordered.append(contentsOf: mcpOutcome.ordered)
        shadowed.append(contentsOf: mcpOutcome.shadowed)

        // 4. Skills (`project .agents` > `project .github` > `user .agents` > `user .copilot`)
        let skillOutcome = resolveNamedArtifacts(
            artifacts.filter { $0.kind == .skill },
            kindLabel: "skill",
            rank: skillPrecedenceRank,
            sourceLabel: skillSourceLabel
        )
        ordered.append(contentsOf: skillOutcome.ordered)
        shadowed.append(contentsOf: skillOutcome.shadowed)

        // 5. Subagents (`project .github/agents` > `user ~/.copilot/agents`)
        let agentOutcome = resolveNamedArtifacts(
            artifacts.filter { $0.kind == .subagent },
            kindLabel: "custom agent",
            rank: { $0.scope == .project ? 0 : 1 },
            sourceLabel: { $0.scope == .project ? "repository custom agent" : "personal custom agent" }
        )
        ordered.append(contentsOf: agentOutcome.ordered)
        shadowed.append(contentsOf: agentOutcome.shadowed)

        // 6. Commands (prompt files)
        let commandOutcome = resolveNamedArtifacts(
            artifacts.filter { $0.kind == .command },
            kindLabel: "prompt command",
            rank: { $0.scope == .project ? 0 : 1 },
            sourceLabel: { $0.scope == .project ? "repository prompt file" : "personal prompt file" }
        )
        ordered.append(contentsOf: commandOutcome.ordered)
        shadowed.append(contentsOf: commandOutcome.shadowed)

        // 7. Hooks (all active hooks fire in user -> project order)
        let hooks = artifacts.filter { $0.kind == .hook }
            .sorted { lhs, rhs in
                let lTier = lhs.scope == .user ? 0 : 1
                let rTier = rhs.scope == .user ? 0 : 1
                if lTier != rTier { return lTier < rTier }
                return lhs.id.rawValue < rhs.id.rawValue
            }
        for hook in hooks {
            ordered.append(
                ResolvedArtifact(
                    artifactID: hook.id,
                    effectiveLoadMode: hook.enabled ? .onInvoke : .never,
                    reason: hook.scope == .project
                        ? "Repository Copilot lifecycle hook" : "Personal Copilot lifecycle hook"
                )
            )
        }

        return Resolution(
            agent: .copilot,
            folder: stdFolder.path,
            ordered: ordered,
            shadowed: shadowed,
            warnings: warnings
        )
    }

    // MARK: - Rules

    private static func resolveRules(
        _ ruleArtifacts: [Artifact],
        repoRoot: URL,
        folder: URL,
        env: AgentEnvironment
    ) -> [ResolvedArtifact] {
        let fs = env.fileSystem

        struct RankedRule {
            let artifact: Artifact
            let bucket: Int
            let depth: Int
            let effectiveMode: LoadMode
            let reason: String
        }

        var ranked: [RankedRule] = []
        for rule in ruleArtifacts {
            guard rule.enabled else {
                ranked.append(
                    RankedRule(
                        artifact: rule,
                        bucket: 99,
                        depth: 0,
                        effectiveMode: .never,
                        reason: "Unreadable or invalid Copilot instruction file"
                    )
                )
                continue
            }

            let ruleURL = URL(fileURLWithPath: rule.location.path).standardizedFileURL
            let parentDir = ruleURL.deletingLastPathComponent().standardizedFileURL

            switch rule.scope {
            case .user:
                ranked.append(
                    RankedRule(
                        artifact: rule,
                        bucket: 0,
                        depth: 0,
                        effectiveMode: .always,
                        reason: "Personal Copilot instructions (\(rule.name))"
                    )
                )

            case .project:
                if CopilotPathCatalog.isModularInstructionFile(ruleURL) {
                    let reason =
                        switch rule.loadMode {
                        case .conditional(let globs):
                            "Path-specific Copilot instructions (applyTo: \(globs.joined(separator: ", ")))"
                        default:
                            "Repository modular Copilot instructions"
                        }
                    ranked.append(
                        RankedRule(
                            artifact: rule,
                            bucket: 5,
                            depth: 0,
                            effectiveMode: rule.loadMode,
                            reason: reason
                        )
                    )
                } else if CopilotPathCatalog.isRepoCopilotInstructionsPath(ruleURL.path) {
                    ranked.append(
                        RankedRule(
                            artifact: rule,
                            bucket: 2,
                            depth: 0,
                            effectiveMode: .always,
                            reason: "Repository Copilot custom instructions"
                        )
                    )
                } else {
                    ranked.append(
                        RankedRule(
                            artifact: rule,
                            bucket: 3,
                            depth: 0,
                            effectiveMode: .always,
                            reason: "Repository root \(rule.name)"
                        )
                    )
                }

            case .directory:
                let isAncestorAboveRepo =
                    AdapterPathNormalizer.relativePath(of: repoRoot, from: parentDir, fileSystem: fs) != nil
                    && parentDir.path != repoRoot.path
                let isOnPathToFolder =
                    AdapterPathNormalizer.relativePath(of: folder, from: parentDir, fileSystem: fs) != nil

                if isAncestorAboveRepo {
                    ranked.append(
                        RankedRule(
                            artifact: rule,
                            bucket: 1,
                            depth: parentDir.pathComponents.count,
                            effectiveMode: .always,
                            reason: "Parent directory instructions above repository root"
                        )
                    )
                } else if isOnPathToFolder {
                    ranked.append(
                        RankedRule(
                            artifact: rule,
                            bucket: 4,
                            depth: parentDir.pathComponents.count,
                            effectiveMode: .always,
                            reason: "Active directory instructions on path to target folder"
                        )
                    )
                } else {
                    let relGlob: String
                    if let relFromFolder = AdapterPathNormalizer.relativePath(
                        of: parentDir, from: folder, fileSystem: fs),
                        !relFromFolder.isEmpty
                    {
                        relGlob = "\(relFromFolder)/**"
                    } else if let relFromRepo = AdapterPathNormalizer.relativePath(
                        of: parentDir,
                        from: repoRoot,
                        fileSystem: fs
                    ), !relFromRepo.isEmpty {
                        relGlob = "\(relFromRepo)/**"
                    } else {
                        relGlob = "**"
                    }
                    ranked.append(
                        RankedRule(
                            artifact: rule,
                            bucket: 6,
                            depth: parentDir.pathComponents.count,
                            effectiveMode: .conditional(globs: [relGlob]),
                            reason: "Nested subdirectory instructions (\(relGlob))"
                        )
                    )
                }

            case .managed, .projectLocal, .builtIn:
                ranked.append(
                    RankedRule(
                        artifact: rule,
                        bucket: 7,
                        depth: 0,
                        effectiveMode: rule.loadMode,
                        reason: "Copilot instructions (\(rule.name))"
                    )
                )
            }
        }

        ranked.sort { lhs, rhs in
            if lhs.bucket != rhs.bucket { return lhs.bucket < rhs.bucket }
            if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
            return lhs.artifact.location.path < rhs.artifact.location.path
        }

        return ranked.map {
            ResolvedArtifact(
                artifactID: $0.artifact.id,
                effectiveLoadMode: $0.effectiveMode,
                reason: $0.reason
            )
        }
    }

    // MARK: - MCP Servers

    private static func resolveMCPServers(
        _ servers: [Artifact]
    ) -> (ordered: [ResolvedArtifact], shadowed: [ShadowRecord]) {
        var grouped: [String: [Artifact]] = [:]
        var malformed: [Artifact] = []

        for server in servers {
            if case .other = server.payload {
                malformed.append(server)
            } else {
                grouped[server.name, default: []].append(server)
            }
        }

        var ordered: [ResolvedArtifact] = []
        var shadowed: [ShadowRecord] = []

        for bad in malformed.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            ordered.append(
                ResolvedArtifact(
                    artifactID: bad.id,
                    effectiveLoadMode: .never,
                    reason: "Malformed Copilot MCP configuration file"
                )
            )
        }

        for name in grouped.keys.sorted() {
            guard var candidates = grouped[name], !candidates.isEmpty else { continue }
            candidates.sort { lhs, rhs in
                let lRank = mcpPrecedenceRank(lhs)
                let rRank = mcpPrecedenceRank(rhs)
                if lRank != rRank { return lRank < rRank }
                return lhs.location.path < rhs.location.path
            }

            let winner = candidates[0]
            let winnerSource = mcpSourceLabel(winner)
            let effectiveMode: LoadMode = winner.enabled ? winner.loadMode : .never
            let reason =
                winner.enabled
                ? "Active Copilot MCP server from \(winnerSource)"
                : "Disabled Copilot MCP server in \(winnerSource)"

            ordered.append(
                ResolvedArtifact(
                    artifactID: winner.id,
                    effectiveLoadMode: effectiveMode,
                    reason: reason
                )
            )

            for loser in candidates.dropFirst() {
                shadowed.append(
                    ShadowRecord(
                        shadowedArtifactID: loser.id,
                        winningArtifactID: winner.id,
                        reason: "Shadowed by higher-precedence MCP server '\(name)' in \(winnerSource)"
                    )
                )
            }
        }

        return (ordered, shadowed)
    }

    private static func mcpPrecedenceRank(_ artifact: Artifact) -> Int {
        if CopilotPathCatalog.isProjectGithubMCPPath(artifact.location.path) {
            return 0
        }
        if CopilotPathCatalog.isProjectVSCodeMCPPath(artifact.location.path) {
            return 1
        }
        if artifact.scope == .project {
            return 2
        }
        return 3
    }

    private static func mcpSourceLabel(_ artifact: Artifact) -> String {
        if CopilotPathCatalog.isProjectGithubMCPPath(artifact.location.path) {
            return "repository MCP configuration"
        }
        if CopilotPathCatalog.isProjectVSCodeMCPPath(artifact.location.path) {
            return "workspace VS Code MCP configuration"
        }
        return "personal Copilot MCP configuration"
    }

    // MARK: - Generic Named Precedence (Skills, Subagents, Prompts)

    private static func skillPrecedenceRank(_ artifact: Artifact) -> Int {
        switch artifact.scope {
        case .project:
            return CopilotPathCatalog.isCrossAgentsSkillsPath(artifact.location.path) ? 0 : 1
        default:
            return CopilotPathCatalog.isCrossAgentsSkillsPath(artifact.location.path) ? 2 : 3
        }
    }

    private static func skillSourceLabel(_ artifact: Artifact) -> String {
        switch artifact.scope {
        case .project:
            return CopilotPathCatalog.isCrossAgentsSkillsPath(artifact.location.path)
                ? "workspace cross-agent skills"
                : "repository Copilot skills"
        default:
            return CopilotPathCatalog.isCrossAgentsSkillsPath(artifact.location.path)
                ? "personal cross-agent skills"
                : "personal Copilot skills"
        }
    }

    private static func resolveNamedArtifacts(
        _ items: [Artifact],
        kindLabel: String,
        rank: (Artifact) -> Int,
        sourceLabel: (Artifact) -> String
    ) -> (ordered: [ResolvedArtifact], shadowed: [ShadowRecord]) {
        var grouped: [String: [Artifact]] = [:]
        for item in items {
            grouped[item.name, default: []].append(item)
        }

        var ordered: [ResolvedArtifact] = []
        var shadowed: [ShadowRecord] = []

        for name in grouped.keys.sorted() {
            guard var candidates = grouped[name], !candidates.isEmpty else { continue }
            candidates.sort { lhs, rhs in
                let lRank = rank(lhs)
                let rRank = rank(rhs)
                if lRank != rRank { return lRank < rRank }
                return lhs.location.path < rhs.location.path
            }

            let winner = candidates[0]
            let label = sourceLabel(winner)
            ordered.append(
                ResolvedArtifact(
                    artifactID: winner.id,
                    effectiveLoadMode: winner.enabled ? winner.loadMode : .never,
                    reason: "Active Copilot \(kindLabel) from \(label)"
                )
            )

            for loser in candidates.dropFirst() {
                shadowed.append(
                    ShadowRecord(
                        shadowedArtifactID: loser.id,
                        winningArtifactID: winner.id,
                        reason: "Shadowed by higher-precedence \(kindLabel) '\(name)' from \(label)"
                    )
                )
            }
        }

        return (ordered, shadowed)
    }
}
