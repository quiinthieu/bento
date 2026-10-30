import BentoCore
import Foundation

/// Read-only filesystem discovery engine for Windsurf across managed, user, project, and nested directory scopes.
enum WindsurfDiscovery {
    struct FolderHierarchy {
        let ancestorsAboveRepo: [URL]
        let repoRoot: URL
        let ancestorsInsideRepoToTarget: [URL]
        let targetFolder: URL
    }

    /// Discovers all Windsurf artifacts at global scope and, when `folder` is provided, workspace scope.
    static func discover(in env: AgentEnvironment, folder: URL?) -> [Artifact] {
        let fs = env.fileSystem
        let hierarchy = resolveFolderHierarchy(for: folder, in: env)
        var artifacts: [Artifact] = []

        // 1. Enterprise managed rules (`/Library/Application Support/Windsurf/rules/*.md`)
        let managedRulesDir = WindsurfPathCatalog.managedRulesDirectory(in: env)
        let managedRuleFiles = AdapterPathNormalizer.collectFilesRecursively(under: managedRulesDir, fileSystem: fs) {
            WindsurfPathCatalog.isMarkdownFile($0)
        }
        for fileURL in managedRuleFiles {
            let relName =
                AdapterPathNormalizer.relativePath(of: fileURL, from: managedRulesDir, fileSystem: fs)
                ?? fileURL.lastPathComponent
            artifacts.append(
                WindsurfPayloadParser.parseRuleFile(
                    at: fileURL,
                    scope: .managed,
                    displayName: relName,
                    parseFrontmatterTrigger: true,
                    maxCharacters: WindsurfPathCatalog.workspaceRuleMaxCharacters,
                    in: env
                )
            )
        }

        // 2. User global rules (`~/.codeium/windsurf/memories/global_rules.md`, 6,000-character limit)
        let globalRulesURL = WindsurfPathCatalog.userGlobalRulesFile(in: env)
        if AdapterPathNormalizer.isEffectiveFile(globalRulesURL, fileSystem: fs) {
            artifacts.append(
                WindsurfPayloadParser.parseRuleFile(
                    at: globalRulesURL,
                    scope: .user,
                    displayName: globalRulesURL.lastPathComponent,
                    parseFrontmatterTrigger: false,
                    defaultLoadMode: .always,
                    maxCharacters: WindsurfPathCatalog.globalRuleMaxCharacters,
                    in: env
                )
            )
        }

        // 3. User MCP (`~/.codeium/windsurf/mcp_config.json`)
        let userMCPURL = WindsurfPathCatalog.userMCPConfigFile(in: env)
        if AdapterPathNormalizer.isEffectiveFile(userMCPURL, fileSystem: fs) {
            artifacts.append(contentsOf: WindsurfPayloadParser.parseMCPFile(at: userMCPURL, scope: .user, in: env))
        }

        // 4. User global workflows (`~/.codeium/windsurf/global_workflows/*.md`)
        artifacts.append(
            contentsOf: discoverWorkflows(
                in: WindsurfPathCatalog.userGlobalWorkflowsDirectory(in: env),
                scope: .user,
                env: env
            )
        )

        // 5. Workspace / Repository / Directory scopes
        if let hierarchy {
            for ancestorDir in hierarchy.ancestorsAboveRepo {
                let agentsFile = WindsurfPathCatalog.agentsMarkdownFile(in: ancestorDir)
                if AdapterPathNormalizer.isEffectiveFile(agentsFile, fileSystem: fs) {
                    artifacts.append(
                        WindsurfPayloadParser.parseRuleFile(
                            at: agentsFile,
                            scope: .directory,
                            displayName: agentsFile.lastPathComponent,
                            parseFrontmatterTrigger: false,
                            defaultLoadMode: .always,
                            maxCharacters: WindsurfPathCatalog.workspaceRuleMaxCharacters,
                            in: env
                        )
                    )
                }
            }

            let repoRoot = hierarchy.repoRoot

            let rootAgents = WindsurfPathCatalog.agentsMarkdownFile(in: repoRoot)
            if AdapterPathNormalizer.isEffectiveFile(rootAgents, fileSystem: fs) {
                artifacts.append(
                    WindsurfPayloadParser.parseRuleFile(
                        at: rootAgents,
                        scope: .project,
                        displayName: rootAgents.lastPathComponent,
                        parseFrontmatterTrigger: false,
                        defaultLoadMode: .always,
                        maxCharacters: WindsurfPathCatalog.workspaceRuleMaxCharacters,
                        in: env
                    )
                )
            }

            let legacyRules = WindsurfPathCatalog.legacyWindsurfRulesFile(in: repoRoot)
            if AdapterPathNormalizer.isEffectiveFile(legacyRules, fileSystem: fs) {
                artifacts.append(
                    WindsurfPayloadParser.parseRuleFile(
                        at: legacyRules,
                        scope: .project,
                        displayName: legacyRules.lastPathComponent,
                        parseFrontmatterTrigger: false,
                        defaultLoadMode: .always,
                        maxCharacters: WindsurfPathCatalog.workspaceRuleMaxCharacters,
                        in: env
                    )
                )
            }

            let workspaceRulesDir = WindsurfPathCatalog.projectRulesDirectory(in: repoRoot)
            let workspaceRuleFiles = AdapterPathNormalizer.collectFilesRecursively(
                under: workspaceRulesDir,
                fileSystem: fs
            ) {
                WindsurfPathCatalog.isMarkdownFile($0)
            }
            for fileURL in workspaceRuleFiles {
                let relName =
                    AdapterPathNormalizer.relativePath(of: fileURL, from: workspaceRulesDir, fileSystem: fs)
                    ?? fileURL.lastPathComponent
                artifacts.append(
                    WindsurfPayloadParser.parseRuleFile(
                        at: fileURL,
                        scope: .project,
                        displayName: relName,
                        parseFrontmatterTrigger: true,
                        maxCharacters: WindsurfPathCatalog.workspaceRuleMaxCharacters,
                        in: env
                    )
                )
            }

            artifacts.append(contentsOf: discoverNestedAgentsMarkdown(hierarchy: hierarchy, env: env))

            artifacts.append(
                contentsOf: discoverWorkflows(
                    in: WindsurfPathCatalog.projectWorkflowsDirectory(in: repoRoot),
                    scope: .project,
                    env: env
                )
            )

            let ignoreFile = WindsurfPathCatalog.projectIgnoreFile(in: repoRoot)
            if AdapterPathNormalizer.isEffectiveFile(ignoreFile, fileSystem: fs),
                let parsed = WindsurfPayloadParser.parseIgnoreFile(at: ignoreFile, scope: .project, in: env)
            {
                artifacts.append(parsed)
            }
        }

        return artifacts
    }

    private static func discoverNestedAgentsMarkdown(
        hierarchy: FolderHierarchy,
        env: AgentEnvironment
    ) -> [Artifact] {
        let fs = env.fileSystem
        let repoRoot = hierarchy.repoRoot
        let rootRealPath = fs.resolveSymlinks(repoRoot).standardizedFileURL.path
        let ancestorPaths = Set(hierarchy.ancestorsInsideRepoToTarget.map { $0.standardizedFileURL.path })

        let nestedFiles = AdapterPathNormalizer.collectFilesRecursively(
            under: repoRoot,
            skippingDirectoryNames: WindsurfPathCatalog.skippedWalkDirectories,
            fileSystem: fs
        ) { url in
            url.lastPathComponent == WindsurfPathCatalog.agentsMarkdownFileName
        }

        var results: [Artifact] = []
        for fileURL in nestedFiles {
            let parentDir = fileURL.deletingLastPathComponent().standardizedFileURL
            let parentRealPath = fs.resolveSymlinks(parentDir).standardizedFileURL.path
            if parentRealPath == rootRealPath {
                continue
            }

            let loadMode: LoadMode
            if ancestorPaths.contains(parentDir.path) {
                loadMode = .always
            } else if let relDir = AdapterPathNormalizer.relativePath(
                of: parentDir,
                from: hierarchy.targetFolder,
                fileSystem: fs
            ), !relDir.isEmpty {
                loadMode = .conditional(globs: ["\(relDir)/**"])
            } else if let relFromRoot = AdapterPathNormalizer.relativePath(
                of: parentDir,
                from: repoRoot,
                fileSystem: fs
            ), !relFromRoot.isEmpty {
                loadMode = .conditional(globs: ["\(relFromRoot)/**"])
            } else {
                loadMode = .conditional(globs: ["**"])
            }

            let displayName =
                AdapterPathNormalizer.relativePath(of: fileURL, from: repoRoot, fileSystem: fs)
                ?? fileURL.lastPathComponent

            results.append(
                WindsurfPayloadParser.parseRuleFile(
                    at: fileURL,
                    scope: .directory,
                    displayName: displayName,
                    parseFrontmatterTrigger: false,
                    defaultLoadMode: loadMode,
                    maxCharacters: WindsurfPathCatalog.workspaceRuleMaxCharacters,
                    in: env
                )
            )
        }

        return results
    }

    private static func discoverWorkflows(in workflowsRoot: URL, scope: Scope, env: AgentEnvironment) -> [Artifact] {
        let files = AdapterPathNormalizer.collectFilesRecursively(under: workflowsRoot, fileSystem: env.fileSystem) {
            WindsurfPathCatalog.isMarkdownFile($0)
        }
        return files.compactMap { WindsurfPayloadParser.parseWorkflowFile(at: $0, scope: scope, in: env) }
    }

    // MARK: - Folder Hierarchy

    static func resolveFolderHierarchy(for folder: URL?, in env: AgentEnvironment) -> FolderHierarchy? {
        guard let rawFolder = folder else { return nil }
        let fs = env.fileSystem
        let stdHome = env.home.standardizedFileURL
        let targetFolder = rawFolder.standardizedFileURL

        let realTarget = fs.resolveSymlinks(targetFolder).standardizedFileURL.path
        let realHome = fs.resolveSymlinks(stdHome).standardizedFileURL.path
        if targetFolder.path == stdHome.path || realTarget == realHome {
            return nil
        }

        var chain: [URL] = []
        if AdapterPathNormalizer.relativePath(of: targetFolder, from: stdHome, fileSystem: fs) != nil {
            var cursor = targetFolder
            while cursor.path != stdHome.path && cursor.path != "/" {
                if fs.resolveSymlinks(cursor).standardizedFileURL.path == realHome {
                    break
                }
                chain.append(cursor)
                let parent = cursor.deletingLastPathComponent().standardizedFileURL
                if parent.path == cursor.path { break }
                cursor = parent
            }
            chain.reverse()
        } else {
            var upward: [URL] = []
            var cursor = targetFolder
            while true {
                upward.append(cursor)
                if WindsurfPathCatalog.hasGitMarker(in: cursor, fileSystem: fs) {
                    break
                }
                let parent = cursor.deletingLastPathComponent().standardizedFileURL
                if parent.path == cursor.path || parent.path == "/" {
                    break
                }
                cursor = parent
            }
            if let gitIdx = upward.firstIndex(where: { WindsurfPathCatalog.hasGitMarker(in: $0, fileSystem: fs) }) {
                chain = Array(upward[0...gitIdx].reversed())
            } else {
                chain = [targetFolder]
            }
        }

        guard !chain.isEmpty else { return nil }

        let repoIndex: Int
        if let nearestGitIdx = chain.lastIndex(where: { WindsurfPathCatalog.hasGitMarker(in: $0, fileSystem: fs) }) {
            repoIndex = nearestGitIdx
        } else if let outermostIdx = chain.firstIndex(where: {
            WindsurfPathCatalog.hasWindsurfRootMarkers(in: $0, fileSystem: fs)
        }) {
            repoIndex = outermostIdx
        } else {
            repoIndex = chain.count - 1
        }

        let ancestorsAbove = Array(chain[0..<repoIndex])
        let repoRoot = chain[repoIndex]
        let ancestorsInside = repoIndex + 1 < chain.count ? Array(chain[(repoIndex + 1)...]) : []

        return FolderHierarchy(
            ancestorsAboveRepo: ancestorsAbove,
            repoRoot: repoRoot,
            ancestorsInsideRepoToTarget: ancestorsInside,
            targetFolder: targetFolder
        )
    }
}
