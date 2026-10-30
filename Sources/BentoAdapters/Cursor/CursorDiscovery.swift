import BentoCore
import Foundation

/// Read-only filesystem discovery engine for Cursor across user, project, and nested directory scopes.
enum CursorDiscovery {
    struct FolderHierarchy {
        let ancestorsAboveRepo: [URL]
        let repoRoot: URL
        let ancestorsInsideRepoToTarget: [URL]
        let targetFolder: URL
    }

    /// Discovers all Cursor artifacts at global scope and, when `folder` is provided, workspace scope.
    static func discover(in env: AgentEnvironment, folder: URL?) -> [Artifact] {
        let fs = env.fileSystem
        let hierarchy = resolveFolderHierarchy(for: folder, in: env)
        var artifacts: [Artifact] = []

        // 1. User scope (`~/.cursor/mcp.json`, `~/.cursor/skills`, `~/.cursor/agents`)
        let userMCP = CursorPathCatalog.userMCPFile(in: env)
        if AdapterPathNormalizer.isEffectiveFile(userMCP, fileSystem: fs) {
            artifacts.append(contentsOf: CursorPayloadParser.parseMCPFile(at: userMCP, scope: .user, in: env))
        }
        artifacts.append(
            contentsOf: discoverSkills(in: CursorPathCatalog.userSkillsDirectory(in: env), scope: .user, env: env)
        )
        artifacts.append(
            contentsOf: discoverSubagents(in: CursorPathCatalog.userAgentsDirectory(in: env), scope: .user, env: env)
        )

        // 2. Workspace / Repository / Directory scopes
        if let hierarchy {
            for ancestorDir in hierarchy.ancestorsAboveRepo {
                let agentsFile = CursorPathCatalog.agentsMarkdownFile(in: ancestorDir)
                if AdapterPathNormalizer.isEffectiveFile(agentsFile, fileSystem: fs) {
                    artifacts.append(
                        CursorPayloadParser.parsePlainRulesFile(
                            at: agentsFile,
                            scope: .directory,
                            name: agentsFile.lastPathComponent,
                            loadMode: .always,
                            in: env
                        )
                    )
                }
            }

            let repoRoot = hierarchy.repoRoot

            let rootAgents = CursorPathCatalog.agentsMarkdownFile(in: repoRoot)
            if AdapterPathNormalizer.isEffectiveFile(rootAgents, fileSystem: fs) {
                artifacts.append(
                    CursorPayloadParser.parsePlainRulesFile(
                        at: rootAgents,
                        scope: .project,
                        name: rootAgents.lastPathComponent,
                        loadMode: .always,
                        in: env
                    )
                )
            }

            let legacyRules = CursorPathCatalog.legacyCursorRulesFile(in: repoRoot)
            if AdapterPathNormalizer.isEffectiveFile(legacyRules, fileSystem: fs) {
                artifacts.append(
                    CursorPayloadParser.parsePlainRulesFile(
                        at: legacyRules,
                        scope: .project,
                        name: legacyRules.lastPathComponent,
                        loadMode: .always,
                        in: env
                    )
                )
            }

            artifacts.append(
                contentsOf: discoverMDCRules(
                    in: CursorPathCatalog.rulesDirectory(in: repoRoot),
                    scope: .project,
                    env: env
                )
            )
            artifacts.append(contentsOf: discoverNestedDirectoryRules(hierarchy: hierarchy, env: env))

            let projectMCP = CursorPathCatalog.projectMCPFile(in: repoRoot)
            if AdapterPathNormalizer.isEffectiveFile(projectMCP, fileSystem: fs) {
                artifacts.append(
                    contentsOf: CursorPayloadParser.parseMCPFile(at: projectMCP, scope: .project, in: env)
                )
            }

            artifacts.append(
                contentsOf: discoverSkills(
                    in: CursorPathCatalog.projectSkillsDirectory(in: repoRoot),
                    scope: .project,
                    env: env
                )
            )
            artifacts.append(
                contentsOf: discoverSubagents(
                    in: CursorPathCatalog.projectAgentsDirectory(in: repoRoot),
                    scope: .project,
                    env: env
                )
            )

            let ignoreFile = CursorPathCatalog.projectIgnoreFile(in: repoRoot)
            if AdapterPathNormalizer.isEffectiveFile(ignoreFile, fileSystem: fs),
                let parsed = CursorPayloadParser.parseIgnoreFile(at: ignoreFile, scope: .project, in: env)
            {
                artifacts.append(parsed)
            }

            let indexingIgnoreFile = CursorPathCatalog.projectIndexingIgnoreFile(in: repoRoot)
            if AdapterPathNormalizer.isEffectiveFile(indexingIgnoreFile, fileSystem: fs),
                let parsed = CursorPayloadParser.parseIgnoreFile(at: indexingIgnoreFile, scope: .project, in: env)
            {
                artifacts.append(parsed)
            }
        }

        return artifacts
    }

    private static func discoverMDCRules(in rulesDir: URL, scope: Scope, env: AgentEnvironment) -> [Artifact] {
        let fs = env.fileSystem
        let files = AdapterPathNormalizer.collectFilesRecursively(under: rulesDir, fileSystem: fs) {
            CursorPathCatalog.isCursorRuleFile($0)
        }

        return files.map { fileURL in
            let relName =
                AdapterPathNormalizer.relativePath(of: fileURL, from: rulesDir, fileSystem: fs)
                ?? fileURL.lastPathComponent
            return CursorPayloadParser.parseMDCRuleFile(
                at: fileURL,
                scope: scope,
                displayName: relName,
                in: env
            )
        }
    }

    private static func discoverNestedDirectoryRules(
        hierarchy: FolderHierarchy,
        env: AgentEnvironment
    ) -> [Artifact] {
        let fs = env.fileSystem
        let repoRoot = hierarchy.repoRoot
        let rootRealPath = fs.resolveSymlinks(repoRoot).standardizedFileURL.path
        let ancestorPaths = Set(hierarchy.ancestorsInsideRepoToTarget.map { $0.standardizedFileURL.path })

        let nestedAgentsFiles = AdapterPathNormalizer.collectFilesRecursively(
            under: repoRoot,
            skippingDirectoryNames: CursorPathCatalog.skippedWalkDirectories,
            fileSystem: fs
        ) { url in
            url.lastPathComponent == CursorPathCatalog.agentsMarkdownFileName
        }

        var results: [Artifact] = []
        for fileURL in nestedAgentsFiles {
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
                CursorPayloadParser.parsePlainRulesFile(
                    at: fileURL,
                    scope: .directory,
                    name: displayName,
                    loadMode: loadMode,
                    in: env
                )
            )
        }

        for subdir in hierarchy.ancestorsInsideRepoToTarget {
            let subRulesDir = CursorPathCatalog.rulesDirectory(in: subdir)
            results.append(contentsOf: discoverMDCRules(in: subRulesDir, scope: .directory, env: env))
        }

        return results
    }

    private static func discoverSkills(in skillsRoot: URL, scope: Scope, env: AgentEnvironment) -> [Artifact] {
        let fs = env.fileSystem
        guard AdapterPathNormalizer.isEffectiveDirectory(skillsRoot, fileSystem: fs),
            let entries = try? fs.list(skillsRoot)
        else {
            return []
        }

        let sortedDirs =
            entries
            .filter {
                !$0.lastPathComponent.hasPrefix(".") && AdapterPathNormalizer.isEffectiveDirectory($0, fileSystem: fs)
            }
            .sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }

        return sortedDirs.compactMap { dir in
            CursorPayloadParser.parseSkillDirectory(at: dir.standardizedFileURL, scope: scope, in: env)
        }
    }

    private static func discoverSubagents(in agentsRoot: URL, scope: Scope, env: AgentEnvironment) -> [Artifact] {
        let files = AdapterPathNormalizer.collectFilesRecursively(under: agentsRoot, fileSystem: env.fileSystem) {
            CursorPathCatalog.isSubagentFile($0)
        }
        return files.compactMap { CursorPayloadParser.parseSubagentFile(at: $0, scope: scope, in: env) }
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
                if CursorPathCatalog.hasGitMarker(in: cursor, fileSystem: fs) {
                    break
                }
                let parent = cursor.deletingLastPathComponent().standardizedFileURL
                if parent.path == cursor.path || parent.path == "/" {
                    break
                }
                cursor = parent
            }
            if let gitIdx = upward.firstIndex(where: { CursorPathCatalog.hasGitMarker(in: $0, fileSystem: fs) }) {
                chain = Array(upward[0...gitIdx].reversed())
            } else {
                chain = [targetFolder]
            }
        }

        guard !chain.isEmpty else { return nil }

        let repoIndex: Int
        if let nearestGitIdx = chain.lastIndex(where: { CursorPathCatalog.hasGitMarker(in: $0, fileSystem: fs) }) {
            repoIndex = nearestGitIdx
        } else if let outermostIdx = chain.firstIndex(where: {
            CursorPathCatalog.hasCursorRootMarkers(in: $0, fileSystem: fs)
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
