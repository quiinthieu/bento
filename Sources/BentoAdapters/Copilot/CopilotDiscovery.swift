import BentoCore
import Foundation

/// Read-only filesystem discovery engine for GitHub Copilot CLI across user, project, and nested directory scopes.
enum CopilotDiscovery {
    struct FolderHierarchy {
        let ancestorsAboveRepo: [URL]
        let repoRoot: URL
        let ancestorsInsideRepoToTarget: [URL]
        let targetFolder: URL
    }

    /// Discovers all Copilot CLI artifacts at global scope and, when `folder` is provided, workspace scope.
    static func discover(in env: AgentEnvironment, folder: URL?) -> [Artifact] {
        let fs = env.fileSystem
        let hierarchy = resolveFolderHierarchy(for: folder, in: env)
        var artifacts: [Artifact] = []

        // 1. User settings (`~/.copilot/config.json`, `~/.copilot/settings.json`)
        let userConfigURL = CopilotPathCatalog.userConfigFile(in: env)
        if AdapterPathNormalizer.isEffectiveFile(userConfigURL, fileSystem: fs) {
            let parsed = CopilotPayloadParser.parseSettingsAndHooks(at: userConfigURL, scope: .user, in: env)
            artifacts.append(parsed.settingsArtifact)
            artifacts.append(contentsOf: parsed.hookArtifacts)
        }

        let userSettingsURL = CopilotPathCatalog.userSettingsFile(in: env)
        if AdapterPathNormalizer.isEffectiveFile(userSettingsURL, fileSystem: fs) {
            let parsed = CopilotPayloadParser.parseSettingsAndHooks(at: userSettingsURL, scope: .user, in: env)
            artifacts.append(parsed.settingsArtifact)
            artifacts.append(contentsOf: parsed.hookArtifacts)
        }

        // 2. User instructions (`~/.copilot/copilot-instructions.md`)
        let userInstructionsURL = CopilotPathCatalog.userInstructionsFile(in: env)
        if AdapterPathNormalizer.isEffectiveFile(userInstructionsURL, fileSystem: fs) {
            artifacts.append(
                CopilotPayloadParser.parsePlainRulesFile(
                    at: userInstructionsURL,
                    scope: .user,
                    name: userInstructionsURL.lastPathComponent,
                    loadMode: .always,
                    in: env
                )
            )
        }

        // 3. User MCP (`~/.copilot/mcp-config.json`)
        let userMCPURL = CopilotPathCatalog.userMCPConfigFile(in: env)
        if AdapterPathNormalizer.isEffectiveFile(userMCPURL, fileSystem: fs) {
            artifacts.append(contentsOf: CopilotPayloadParser.parseMCPFile(at: userMCPURL, scope: .user, in: env))
        }

        // 4. User skills (`~/.agents/skills/*/SKILL.md`, `~/.copilot/skills/*/SKILL.md`)
        artifacts.append(
            contentsOf: discoverSkills(
                in: CopilotPathCatalog.userAgentsSkillsDirectory(in: env), scope: .user, env: env)
        )
        artifacts.append(
            contentsOf: discoverSkills(
                in: CopilotPathCatalog.userCopilotSkillsDirectory(in: env), scope: .user, env: env)
        )

        // 5. User custom agents (`~/.copilot/agents/*.agent.md`)
        artifacts.append(
            contentsOf: discoverSubagents(in: CopilotPathCatalog.userAgentsDirectory(in: env), scope: .user, env: env)
        )

        // 6. User hooks (`~/.copilot/hooks/*.json`)
        artifacts.append(
            contentsOf: discoverHooks(in: CopilotPathCatalog.userHooksDirectory(in: env), scope: .user, env: env)
        )

        // 7. Workspace / Repository / Directory scopes
        if let hierarchy {
            for ancestorDir in hierarchy.ancestorsAboveRepo {
                let agentsFile = CopilotPathCatalog.agentsMarkdownFile(in: ancestorDir)
                if AdapterPathNormalizer.isEffectiveFile(agentsFile, fileSystem: fs) {
                    artifacts.append(
                        CopilotPayloadParser.parsePlainRulesFile(
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

            let projectInstructions = CopilotPathCatalog.projectInstructionsFile(in: repoRoot)
            if AdapterPathNormalizer.isEffectiveFile(projectInstructions, fileSystem: fs) {
                artifacts.append(
                    CopilotPayloadParser.parsePlainRulesFile(
                        at: projectInstructions,
                        scope: .project,
                        name: projectInstructions.lastPathComponent,
                        loadMode: .always,
                        in: env
                    )
                )
            }

            let rootAgents = CopilotPathCatalog.agentsMarkdownFile(in: repoRoot)
            if AdapterPathNormalizer.isEffectiveFile(rootAgents, fileSystem: fs) {
                artifacts.append(
                    CopilotPayloadParser.parsePlainRulesFile(
                        at: rootAgents,
                        scope: .project,
                        name: rootAgents.lastPathComponent,
                        loadMode: .always,
                        in: env
                    )
                )
            }

            artifacts.append(contentsOf: discoverModularInstructions(in: repoRoot, env: env))
            artifacts.append(contentsOf: discoverNestedAgentsMarkdown(hierarchy: hierarchy, env: env))

            let githubMCP = CopilotPathCatalog.projectGithubMCPFile(in: repoRoot)
            if AdapterPathNormalizer.isEffectiveFile(githubMCP, fileSystem: fs) {
                artifacts.append(
                    contentsOf: CopilotPayloadParser.parseMCPFile(at: githubMCP, scope: .project, in: env)
                )
            }

            let vscodeMCP = CopilotPathCatalog.projectVSCodeMCPFile(in: repoRoot)
            if AdapterPathNormalizer.isEffectiveFile(vscodeMCP, fileSystem: fs) {
                artifacts.append(
                    contentsOf: CopilotPayloadParser.parseMCPFile(at: vscodeMCP, scope: .project, in: env)
                )
            }

            artifacts.append(
                contentsOf: discoverSkills(
                    in: CopilotPathCatalog.projectAgentsSkillsDirectory(in: repoRoot),
                    scope: .project,
                    env: env
                )
            )
            artifacts.append(
                contentsOf: discoverSkills(
                    in: CopilotPathCatalog.projectGithubSkillsDirectory(in: repoRoot),
                    scope: .project,
                    env: env
                )
            )
            artifacts.append(
                contentsOf: discoverSubagents(
                    in: CopilotPathCatalog.projectAgentsDirectory(in: repoRoot),
                    scope: .project,
                    env: env
                )
            )
            artifacts.append(
                contentsOf: discoverPrompts(
                    in: CopilotPathCatalog.projectPromptsDirectory(in: repoRoot),
                    scope: .project,
                    env: env
                )
            )
            artifacts.append(
                contentsOf: discoverHooks(
                    in: CopilotPathCatalog.projectHooksDirectory(in: repoRoot),
                    scope: .project,
                    env: env
                )
            )
        }

        return artifacts
    }

    // MARK: - Sub-discoverers

    private static func discoverModularInstructions(in repoRoot: URL, env: AgentEnvironment) -> [Artifact] {
        let fs = env.fileSystem
        let instructionsDir = CopilotPathCatalog.projectModularInstructionsDirectory(in: repoRoot)
        let files = AdapterPathNormalizer.collectFilesRecursively(under: instructionsDir, fileSystem: fs) {
            CopilotPathCatalog.isModularInstructionFile($0)
        }

        return files.map { fileURL in
            let relName =
                AdapterPathNormalizer.relativePath(of: fileURL, from: instructionsDir, fileSystem: fs)
                ?? fileURL.lastPathComponent
            return CopilotPayloadParser.parseModularInstructionFile(
                at: fileURL,
                scope: .project,
                displayName: relName,
                in: env
            )
        }
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
            skippingDirectoryNames: CopilotPathCatalog.skippedWalkDirectories,
            fileSystem: fs
        ) { url in
            url.lastPathComponent == CopilotPathCatalog.agentsMarkdownFileName
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
                CopilotPayloadParser.parsePlainRulesFile(
                    at: fileURL,
                    scope: .directory,
                    name: displayName,
                    loadMode: loadMode,
                    in: env
                )
            )
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
            CopilotPayloadParser.parseSkillDirectory(at: dir.standardizedFileURL, scope: scope, in: env)
        }
    }

    private static func discoverSubagents(in agentsRoot: URL, scope: Scope, env: AgentEnvironment) -> [Artifact] {
        let files = AdapterPathNormalizer.collectFilesRecursively(under: agentsRoot, fileSystem: env.fileSystem) {
            CopilotPathCatalog.isCustomAgentFile($0)
        }
        return files.compactMap { CopilotPayloadParser.parseSubagentFile(at: $0, scope: scope, in: env) }
    }

    private static func discoverPrompts(in promptsRoot: URL, scope: Scope, env: AgentEnvironment) -> [Artifact] {
        let files = AdapterPathNormalizer.collectFilesRecursively(under: promptsRoot, fileSystem: env.fileSystem) {
            CopilotPathCatalog.isPromptCommandFile($0)
        }
        return files.compactMap { CopilotPayloadParser.parsePromptCommandFile(at: $0, scope: scope, in: env) }
    }

    private static func discoverHooks(in hooksRoot: URL, scope: Scope, env: AgentEnvironment) -> [Artifact] {
        let files = AdapterPathNormalizer.collectFilesRecursively(under: hooksRoot, fileSystem: env.fileSystem) {
            CopilotPathCatalog.isHookConfigFile($0)
        }
        return files.flatMap { CopilotPayloadParser.parseHooksFile(at: $0, scope: scope, in: env) }
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
                if CopilotPathCatalog.hasGitMarker(in: cursor, fileSystem: fs) {
                    break
                }
                let parent = cursor.deletingLastPathComponent().standardizedFileURL
                if parent.path == cursor.path || parent.path == "/" {
                    break
                }
                cursor = parent
            }
            if let gitIdx = upward.firstIndex(where: { CopilotPathCatalog.hasGitMarker(in: $0, fileSystem: fs) }) {
                chain = Array(upward[0...gitIdx].reversed())
            } else {
                chain = [targetFolder]
            }
        }

        guard !chain.isEmpty else { return nil }

        let repoIndex: Int
        if let nearestGitIdx = chain.lastIndex(where: { CopilotPathCatalog.hasGitMarker(in: $0, fileSystem: fs) }) {
            repoIndex = nearestGitIdx
        } else if let outermostIdx = chain.firstIndex(where: {
            CopilotPathCatalog.hasCopilotRootMarkers(in: $0, fileSystem: fs)
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
