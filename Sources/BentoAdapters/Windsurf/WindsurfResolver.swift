import BentoCore
import Foundation

/// Precedence and shadowing resolver for Windsurf Cascade (`Docs/adapters/windsurf.md`).
enum WindsurfResolver {
    static func resolve(_ artifacts: [Artifact], folder: URL, env: AgentEnvironment) -> Resolution {
        let stdFolder = folder.standardizedFileURL
        let hierarchy = WindsurfDiscovery.resolveFolderHierarchy(for: stdFolder, in: env)
        let repoRoot = hierarchy?.repoRoot ?? stdFolder

        var ordered: [ResolvedArtifact] = []
        var shadowed: [ShadowRecord] = []
        var warnings: [Diagnostic] = []

        for artifact in artifacts {
            warnings.append(contentsOf: artifact.diagnostics)
        }

        // 1. Rules (enterprise -> global -> ancestor AGENTS.md -> root AGENTS.md -> .windsurfrules -> .windsurf/rules -> nested AGENTS.md)
        ordered.append(
            contentsOf: resolveRules(
                artifacts.filter { $0.kind == .rules },
                repoRoot: repoRoot,
                folder: stdFolder,
                env: env
            )
        )

        // 2. MCP servers
        let mcpOutcome = resolveProjectOverUser(
            artifacts.filter { $0.kind == .mcpServer },
            kindLabel: "MCP server"
        )
        ordered.append(contentsOf: mcpOutcome.ordered)
        shadowed.append(contentsOf: mcpOutcome.shadowed)

        // 3. Workflows (`project` > `user`)
        let workflowOutcome = resolveProjectOverUser(
            artifacts.filter { $0.kind == .command },
            kindLabel: "workflow"
        )
        ordered.append(contentsOf: workflowOutcome.ordered)
        shadowed.append(contentsOf: workflowOutcome.shadowed)

        // 4. Ignore files
        let ignoreFiles = artifacts.filter { $0.kind == .ignoreFile }
            .sorted { $0.location.path < $1.location.path }
        for ignore in ignoreFiles {
            ordered.append(
                ResolvedArtifact(
                    artifactID: ignore.id,
                    effectiveLoadMode: .never,
                    reason: "Windsurf context exclusion rules (\(ignore.name))"
                )
            )
        }

        return Resolution(
            agent: .windsurf,
            folder: stdFolder.path,
            ordered: ordered,
            shadowed: shadowed,
            warnings: warnings
        )
    }

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
                        reason: "Unreadable or invalid Windsurf rule file"
                    )
                )
                continue
            }

            let ruleURL = URL(fileURLWithPath: rule.location.path).standardizedFileURL

            switch rule.scope {
            case .managed:
                ranked.append(
                    RankedRule(
                        artifact: rule,
                        bucket: 0,
                        depth: 0,
                        effectiveMode: rule.loadMode,
                        reason: "Enterprise system Windsurf rule"
                    )
                )

            case .user:
                ranked.append(
                    RankedRule(
                        artifact: rule,
                        bucket: 1,
                        depth: 0,
                        effectiveMode: .always,
                        reason: "Global Windsurf Cascade rules"
                    )
                )

            case .project:
                if WindsurfPathCatalog.isWorkspaceRulesDirectoryPath(ruleURL.path) {
                    let reason =
                        switch rule.loadMode {
                        case .always:
                            "Workspace Windsurf rule (always_on)"
                        case .conditional(let globs):
                            "Workspace Windsurf glob rule (\(globs.joined(separator: ", ")))"
                        default:
                            "Workspace Windsurf model/manual-invoked rule"
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
                } else if WindsurfPathCatalog.isLegacyWindsurfRulesPath(ruleURL.path) {
                    ranked.append(
                        RankedRule(
                            artifact: rule,
                            bucket: 4,
                            depth: 0,
                            effectiveMode: .always,
                            reason: "Legacy Windsurf workspace rules"
                        )
                    )
                } else {
                    ranked.append(
                        RankedRule(
                            artifact: rule,
                            bucket: 3,
                            depth: 0,
                            effectiveMode: .always,
                            reason: "Workspace root \(rule.name)"
                        )
                    )
                }

            case .directory:
                let parentDir = ruleURL.deletingLastPathComponent().standardizedFileURL
                let isAncestorAboveRepo =
                    AdapterPathNormalizer.relativePath(of: repoRoot, from: parentDir, fileSystem: fs) != nil
                    && parentDir.path != repoRoot.path
                let isOnPathToFolder =
                    AdapterPathNormalizer.relativePath(of: folder, from: parentDir, fileSystem: fs) != nil

                if isAncestorAboveRepo {
                    ranked.append(
                        RankedRule(
                            artifact: rule,
                            bucket: 2,
                            depth: parentDir.pathComponents.count,
                            effectiveMode: .always,
                            reason: "Parent directory instructions above repository root"
                        )
                    )
                } else if isOnPathToFolder {
                    ranked.append(
                        RankedRule(
                            artifact: rule,
                            bucket: 6,
                            depth: parentDir.pathComponents.count,
                            effectiveMode: .always,
                            reason: "Active subdirectory instructions on path to target folder"
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
                            bucket: 7,
                            depth: parentDir.pathComponents.count,
                            effectiveMode: .conditional(globs: [relGlob]),
                            reason: "Nested subdirectory instructions (\(relGlob))"
                        )
                    )
                }

            case .projectLocal, .builtIn:
                ranked.append(
                    RankedRule(
                        artifact: rule,
                        bucket: 8,
                        depth: 0,
                        effectiveMode: rule.loadMode,
                        reason: "Windsurf rule (\(rule.name))"
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

    private static func resolveProjectOverUser(
        _ items: [Artifact],
        kindLabel: String
    ) -> (ordered: [ResolvedArtifact], shadowed: [ShadowRecord]) {
        var grouped: [String: [Artifact]] = [:]
        var malformed: [Artifact] = []

        for item in items {
            if case .other = item.payload {
                malformed.append(item)
            } else {
                grouped[item.name, default: []].append(item)
            }
        }

        var ordered: [ResolvedArtifact] = []
        var shadowed: [ShadowRecord] = []

        for bad in malformed.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            ordered.append(
                ResolvedArtifact(
                    artifactID: bad.id,
                    effectiveLoadMode: .never,
                    reason: "Malformed Windsurf \(kindLabel) configuration"
                )
            )
        }

        for name in grouped.keys.sorted() {
            guard var candidates = grouped[name], !candidates.isEmpty else { continue }
            candidates.sort { lhs, rhs in
                let lRank = lhs.scope == .project ? 0 : 1
                let rRank = rhs.scope == .project ? 0 : 1
                if lRank != rRank { return lRank < rRank }
                return lhs.location.path < rhs.location.path
            }

            let winner = candidates[0]
            let source = winner.scope == .project ? "workspace Windsurf configuration" : "global Windsurf configuration"
            let effectiveMode = winner.enabled ? winner.loadMode : .never
            let reason =
                winner.enabled
                ? "Active Windsurf \(kindLabel) from \(source)"
                : "Disabled Windsurf \(kindLabel) in \(source)"

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
                        reason: "Shadowed by workspace Windsurf \(kindLabel) '\(name)'"
                    )
                )
            }
        }

        return (ordered, shadowed)
    }
}
