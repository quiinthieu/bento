import BentoCore
import BentoParsing
import Foundation

/// Read-only filesystem discovery engine for Claude Code across managed, user, plugin, project, and nested directory scopes.
enum ClaudeCodeDiscovery {
    struct FolderHierarchy {
        let ancestorsAboveRepo: [URL]
        let repoRoot: URL
        let ancestorsInsideRepoToTarget: [URL]
        let targetFolder: URL
    }

    private struct InstalledPluginSelection {
        var installURL: URL?
        var version: String?
    }

    private struct PluginCandidate {
        let pluginKey: String
        let shortName: String
        let dirVersion: String
        let pluginDir: URL
        let manifestURL: URL
    }

    /// Discovers all Claude Code artifacts at global scope and, when `folder` is provided, workspace scope.
    static func discover(in env: AgentEnvironment, folder: URL?) -> [Artifact] {
        let fs = env.fileSystem
        let hierarchy = resolveFolderHierarchy(for: folder, in: env)

        // 1. Pre-parse settings files across tiers so enabledPlugins is known before scanning plugins.
        let managedSettingsURL = ClaudeCodePathCatalog.managedSettingsFile(in: env)
        let userSettingsURL = ClaudeCodePathCatalog.userSettingsFile(in: env)

        let managedParsed =
            AdapterPathNormalizer.isEffectiveFile(managedSettingsURL, fileSystem: fs)
            ? ClaudeCodePayloadParser.parseSettingsAndHooks(at: managedSettingsURL, scope: .managed, in: env)
            : nil
        let userParsed =
            AdapterPathNormalizer.isEffectiveFile(userSettingsURL, fileSystem: fs)
            ? ClaudeCodePayloadParser.parseSettingsAndHooks(at: userSettingsURL, scope: .user, in: env)
            : nil

        var projectParsed: (settingsArtifact: Artifact, hookArtifacts: [Artifact], parsedTree: [String: JSONValue]?)?
        var projectLocalParsed:
            (settingsArtifact: Artifact, hookArtifacts: [Artifact], parsedTree: [String: JSONValue]?)?

        if let repoRoot = hierarchy?.repoRoot {
            let projSettingsURL = ClaudeCodePathCatalog.projectSettingsFile(in: repoRoot)
            if AdapterPathNormalizer.isEffectiveFile(projSettingsURL, fileSystem: fs) {
                projectParsed = ClaudeCodePayloadParser.parseSettingsAndHooks(
                    at: projSettingsURL,
                    scope: .project,
                    in: env
                )
            }
            let localSettingsURL = ClaudeCodePathCatalog.projectLocalSettingsFile(in: repoRoot)
            if AdapterPathNormalizer.isEffectiveFile(localSettingsURL, fileSystem: fs) {
                projectLocalParsed = ClaudeCodePayloadParser.parseSettingsAndHooks(
                    at: localSettingsURL,
                    scope: .projectLocal,
                    in: env
                )
            }
        }

        let settingsPrecedenceTrees: [[String: JSONValue]] = [
            managedParsed?.parsedTree,
            projectLocalParsed?.parsedTree,
            projectParsed?.parsedTree,
            userParsed?.parsedTree
        ].compactMap { $0 }

        // Pre-compute real paths of primary memory/rule files so @import expansion never duplicates primary files.
        let primaryRuleRealPaths = collectPrimaryRuleRealPaths(hierarchy: hierarchy, in: env)
        var emittedRuleRealPaths: Set<String> = []
        var artifacts: [Artifact] = []

        // 2. Managed scope
        if let managedParsed {
            artifacts.append(managedParsed.settingsArtifact)
            artifacts.append(contentsOf: managedParsed.hookArtifacts)
        }

        let managedMCPURL = ClaudeCodePathCatalog.managedMCPFile(in: env)
        if AdapterPathNormalizer.isEffectiveFile(managedMCPURL, fileSystem: fs) {
            artifacts.append(
                contentsOf: ClaudeCodePayloadParser.parseMCPFile(at: managedMCPURL, scope: .managed, in: env))
        }

        let managedMemoryURL = ClaudeCodePathCatalog.managedMemoryFile(in: env)
        artifacts.append(
            contentsOf: discoverMemoryFile(
                at: managedMemoryURL,
                scope: .managed,
                loadMode: .always,
                primaryRuleRealPaths: primaryRuleRealPaths,
                emittedRuleRealPaths: &emittedRuleRealPaths,
                in: env
            )
        )

        artifacts.append(
            contentsOf: discoverSkills(
                in: ClaudeCodePathCatalog.managedSkillsDirectory(in: env),
                scope: .managed,
                in: env
            )
        )
        artifacts.append(
            contentsOf: discoverSubagents(
                in: ClaudeCodePathCatalog.managedAgentsDirectory(in: env),
                scope: .managed,
                in: env
            )
        )

        // 3. User scope
        if let userParsed {
            artifacts.append(userParsed.settingsArtifact)
            artifacts.append(contentsOf: userParsed.hookArtifacts)
        }

        artifacts.append(contentsOf: discoverUserState(hierarchy: hierarchy, in: env))

        let userMemoryURL = ClaudeCodePathCatalog.userMemoryFile(in: env)
        artifacts.append(
            contentsOf: discoverMemoryFile(
                at: userMemoryURL,
                scope: .user,
                loadMode: .always,
                primaryRuleRealPaths: primaryRuleRealPaths,
                emittedRuleRealPaths: &emittedRuleRealPaths,
                in: env
            )
        )

        artifacts.append(
            contentsOf: discoverModularRules(
                in: ClaudeCodePathCatalog.userRulesDirectory(in: env),
                scope: .user,
                emittedRuleRealPaths: &emittedRuleRealPaths,
                in: env
            )
        )
        artifacts.append(
            contentsOf: discoverSkills(
                in: ClaudeCodePathCatalog.userSkillsDirectory(in: env),
                scope: .user,
                in: env
            )
        )
        artifacts.append(
            contentsOf: discoverSubagents(
                in: ClaudeCodePathCatalog.userAgentsDirectory(in: env),
                scope: .user,
                in: env
            )
        )
        artifacts.append(
            contentsOf: discoverCommands(
                in: ClaudeCodePathCatalog.userCommandsDirectory(in: env),
                scope: .user,
                in: env
            )
        )

        // 4. Plugins scope
        artifacts.append(
            contentsOf: discoverPlugins(
                settingsPrecedenceTrees: settingsPrecedenceTrees,
                in: env
            )
        )

        // 5. Workspace / Repo / Directory scopes
        if let hierarchy {
            for ancestorDir in hierarchy.ancestorsAboveRepo {
                artifacts.append(
                    contentsOf: discoverDirectoryMemoryFiles(
                        in: ancestorDir,
                        scope: .directory,
                        loadMode: .always,
                        includeDotClaudeMemory: true,
                        primaryRuleRealPaths: primaryRuleRealPaths,
                        emittedRuleRealPaths: &emittedRuleRealPaths,
                        env: env
                    )
                )
            }

            if let projectParsed {
                artifacts.append(projectParsed.settingsArtifact)
                artifacts.append(contentsOf: projectParsed.hookArtifacts)
            }
            if let projectLocalParsed {
                artifacts.append(projectLocalParsed.settingsArtifact)
                artifacts.append(contentsOf: projectLocalParsed.hookArtifacts)
            }

            let projectMCPURL = ClaudeCodePathCatalog.projectMCPFile(in: hierarchy.repoRoot)
            if AdapterPathNormalizer.isEffectiveFile(projectMCPURL, fileSystem: fs) {
                artifacts.append(
                    contentsOf: ClaudeCodePayloadParser.parseMCPFile(
                        at: projectMCPURL,
                        scope: .project,
                        in: env
                    )
                )
            }

            let repoRoot = hierarchy.repoRoot
            artifacts.append(
                contentsOf: discoverMemoryFile(
                    at: ClaudeCodePathCatalog.memoryFile(in: repoRoot),
                    scope: .project,
                    loadMode: .always,
                    primaryRuleRealPaths: primaryRuleRealPaths,
                    emittedRuleRealPaths: &emittedRuleRealPaths,
                    in: env
                )
            )
            artifacts.append(
                contentsOf: discoverMemoryFile(
                    at: ClaudeCodePathCatalog.dotClaudeMemoryFile(in: repoRoot),
                    scope: .project,
                    loadMode: .always,
                    primaryRuleRealPaths: primaryRuleRealPaths,
                    emittedRuleRealPaths: &emittedRuleRealPaths,
                    in: env
                )
            )
            artifacts.append(
                contentsOf: discoverMemoryFile(
                    at: ClaudeCodePathCatalog.localMemoryFile(in: repoRoot),
                    scope: .projectLocal,
                    loadMode: .always,
                    primaryRuleRealPaths: primaryRuleRealPaths,
                    emittedRuleRealPaths: &emittedRuleRealPaths,
                    in: env
                )
            )

            artifacts.append(
                contentsOf: discoverModularRules(
                    in: ClaudeCodePathCatalog.projectRulesDirectory(in: repoRoot),
                    scope: .project,
                    emittedRuleRealPaths: &emittedRuleRealPaths,
                    in: env
                )
            )
            artifacts.append(
                contentsOf: discoverSkills(
                    in: ClaudeCodePathCatalog.projectSkillsDirectory(in: repoRoot),
                    scope: .project,
                    in: env
                )
            )
            artifacts.append(
                contentsOf: discoverSubagents(
                    in: ClaudeCodePathCatalog.projectAgentsDirectory(in: repoRoot),
                    scope: .project,
                    in: env
                )
            )
            artifacts.append(
                contentsOf: discoverCommands(
                    in: ClaudeCodePathCatalog.projectCommandsDirectory(in: repoRoot),
                    scope: .project,
                    in: env
                )
            )

            for subdir in hierarchy.ancestorsInsideRepoToTarget {
                artifacts.append(
                    contentsOf: discoverDirectoryMemoryFiles(
                        in: subdir,
                        scope: .directory,
                        loadMode: .always,
                        includeDotClaudeMemory: true,
                        primaryRuleRealPaths: primaryRuleRealPaths,
                        emittedRuleRealPaths: &emittedRuleRealPaths,
                        env: env
                    )
                )
            }

            artifacts.append(
                contentsOf: discoverDescendantMemoryFiles(
                    hierarchy: hierarchy,
                    primaryRuleRealPaths: primaryRuleRealPaths,
                    emittedRuleRealPaths: &emittedRuleRealPaths,
                    in: env
                )
            )
        }

        return artifacts
    }

    // MARK: - Hierarchy Resolution

    static func resolveFolderHierarchy(for folder: URL?, in env: AgentEnvironment) -> FolderHierarchy? {
        guard let folder else { return nil }
        let fs = env.fileSystem
        let targetFolder = folder.standardizedFileURL
        let stdHome = env.home.standardizedFileURL

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
                if ClaudeCodePathCatalog.hasGitMarker(in: cursor, fileSystem: fs) {
                    break
                }
                let parent = cursor.deletingLastPathComponent().standardizedFileURL
                if parent.path == cursor.path || parent.path == "/" {
                    break
                }
                cursor = parent
            }
            let gitRootIndex = upward.firstIndex { ClaudeCodePathCatalog.hasGitMarker(in: $0, fileSystem: fs) }
            if let gitRootIndex {
                chain = Array(upward[0...gitRootIndex].reversed())
            } else {
                chain = [targetFolder]
            }
        }

        guard !chain.isEmpty else { return nil }

        let repoIndex: Int
        if let nearestGitIdx = chain.lastIndex(where: { ClaudeCodePathCatalog.hasGitMarker(in: $0, fileSystem: fs) }) {
            repoIndex = nearestGitIdx
        } else if let outermostClaudeIdx = chain.firstIndex(where: {
            ClaudeCodePathCatalog.hasClaudeRootMarkers(in: $0, fileSystem: fs)
        }) {
            repoIndex = outermostClaudeIdx
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

    // MARK: - User State (~/.claude.json)

    private static func discoverUserState(hierarchy: FolderHierarchy?, in env: AgentEnvironment) -> [Artifact] {
        let stateURL = ClaudeCodePathCatalog.userStateFile(in: env)
        guard AdapterPathNormalizer.isEffectiveFile(stateURL, fileSystem: env.fileSystem),
            let rawData = try? env.fileSystem.contents(at: stateURL)
        else {
            return []
        }

        let baseLocation = AdapterPathNormalizer.sourceLocation(for: stateURL, in: env)
        let contentHash = ClaudeCodePayloadParser.hashData(rawData)
        let (settingsDoc, diagnostics) = JSONCParser.parseSettings(rawData, location: baseLocation)

        guard let tree = settingsDoc?.tree else {
            let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: stateURL, in: env)
            let errID = ArtifactID(agent: .claudeCode, kind: .mcpServer, scope: .user, path: identityPath)
            return [
                Artifact(
                    id: errID,
                    agent: .claudeCode,
                    kind: .mcpServer,
                    scope: .user,
                    name: stateURL.lastPathComponent,
                    location: baseLocation,
                    contentHash: contentHash,
                    enabled: false,
                    loadMode: .never,
                    payload: .other,
                    diagnostics: diagnostics
                )
            ]
        }

        var results: [Artifact] = []

        if case .object(let userMCP) = tree["mcpServers"] {
            results.append(
                contentsOf: ClaudeCodePayloadParser.parseMCPServersDictionary(
                    userMCP,
                    keyPrefix: ["mcpServers"],
                    fileURL: stateURL,
                    scope: .user,
                    contentHash: contentHash,
                    in: env
                )
            )
        }

        if let hierarchy, case .object(let projectsMap) = tree["projects"] {
            let candidateFolders = [hierarchy.repoRoot] + hierarchy.ancestorsInsideRepoToTarget
            let candidateRealPaths = Set(
                candidateFolders.map { env.fileSystem.resolveSymlinks($0).standardizedFileURL.path }
                    + candidateFolders.map { $0.standardizedFileURL.path }
            )

            for rawProjectKey in projectsMap.keys.sorted() {
                let expandedURL = AdapterPathNormalizer.expandHomePrefix(rawProjectKey, in: env)
                let expandedStd = expandedURL.standardizedFileURL.path
                let expandedReal = env.fileSystem.resolveSymlinks(expandedURL).standardizedFileURL.path

                guard candidateRealPaths.contains(expandedStd) || candidateRealPaths.contains(expandedReal) else {
                    continue
                }

                guard case .object(let projectEntry) = projectsMap[rawProjectKey],
                    case .object(let localMCP) = projectEntry["mcpServers"]
                else {
                    continue
                }

                results.append(
                    contentsOf: ClaudeCodePayloadParser.parseMCPServersDictionary(
                        localMCP,
                        keyPrefix: ["projects", rawProjectKey, "mcpServers"],
                        fileURL: stateURL,
                        scope: .projectLocal,
                        contentHash: contentHash,
                        in: env
                    )
                )
            }
        }

        return results
    }

    // MARK: - Memory & Rules

    private static func collectPrimaryRuleRealPaths(
        hierarchy: FolderHierarchy?,
        in env: AgentEnvironment
    ) -> Set<String> {
        let fs = env.fileSystem
        var candidates: [URL] = [
            ClaudeCodePathCatalog.managedMemoryFile(in: env),
            ClaudeCodePathCatalog.userMemoryFile(in: env)
        ]

        candidates.append(
            contentsOf: AdapterPathNormalizer.collectFilesRecursively(
                under: ClaudeCodePathCatalog.userRulesDirectory(in: env),
                fileSystem: fs
            ) { $0.pathExtension.lowercased() == "md" }
        )

        if let hierarchy {
            let dirs = [hierarchy.repoRoot] + hierarchy.ancestorsAboveRepo + hierarchy.ancestorsInsideRepoToTarget
            for dir in dirs {
                candidates.append(ClaudeCodePathCatalog.memoryFile(in: dir))
                candidates.append(ClaudeCodePathCatalog.dotClaudeMemoryFile(in: dir))
                candidates.append(ClaudeCodePathCatalog.localMemoryFile(in: dir))
            }
            candidates.append(
                contentsOf: AdapterPathNormalizer.collectFilesRecursively(
                    under: ClaudeCodePathCatalog.projectRulesDirectory(in: hierarchy.repoRoot),
                    fileSystem: fs
                ) { $0.pathExtension.lowercased() == "md" }
            )
            candidates.append(
                contentsOf: AdapterPathNormalizer.collectFilesRecursively(
                    under: hierarchy.repoRoot,
                    skippingDirectoryNames: ClaudeCodePathCatalog.skippedDescendantDirectoryNames,
                    fileSystem: fs
                ) {
                    $0.lastPathComponent == ClaudeCodePathCatalog.memoryFilename
                        || $0.lastPathComponent == ClaudeCodePathCatalog.localMemoryFilename
                }
            )
        }

        var realPaths: Set<String> = []
        for url in candidates where AdapterPathNormalizer.isEffectiveFile(url, fileSystem: fs) {
            realPaths.insert(fs.resolveSymlinks(url).standardizedFileURL.path)
        }
        return realPaths
    }

    private static func discoverMemoryFile(
        at fileURL: URL,
        scope: Scope,
        loadMode: LoadMode,
        primaryRuleRealPaths: Set<String>,
        emittedRuleRealPaths: inout Set<String>,
        in env: AgentEnvironment
    ) -> [Artifact] {
        let fs = env.fileSystem
        guard AdapterPathNormalizer.isEffectiveFile(fileURL, fileSystem: fs),
            let rawData = try? fs.contents(at: fileURL)
        else {
            return []
        }

        let realPath = fs.resolveSymlinks(fileURL).standardizedFileURL.path
        guard emittedRuleRealPaths.insert(realPath).inserted else {
            return []
        }

        let location = AdapterPathNormalizer.sourceLocation(for: fileURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        let id = ArtifactID(agent: .claudeCode, kind: .rules, scope: scope, path: identityPath)

        guard let rawText = String(data: rawData, encoding: .utf8) else {
            let diag = Diagnostic(
                code: "rules.invalidUTF8",
                severity: .warning,
                message: "Memory file '\(fileURL.lastPathComponent)' is not valid UTF-8",
                location: location
            )
            return [
                Artifact(
                    id: id,
                    agent: .claudeCode,
                    kind: .rules,
                    scope: scope,
                    name: fileURL.lastPathComponent,
                    location: location,
                    contentHash: ContentHasher.sha256Hex(rawData),
                    enabled: false,
                    loadMode: .never,
                    payload: .other,
                    diagnostics: [diag]
                )
            ]
        }

        let importResolution = ImportResolver(syntax: .claudeCode).resolve(
            markdown: rawText,
            sourceURL: fileURL,
            homeURL: env.home,
            fileSystem: fs
        )

        let doc = RulesDoc(
            content: rawText,
            imports: importResolution.directImports,
            frontmatter: nil,
            byteCount: rawData.count,
            characterCount: rawText.count,
            wasTruncated: false
        )

        var output: [Artifact] = [
            Artifact(
                id: id,
                agent: .claudeCode,
                kind: .rules,
                scope: scope,
                name: fileURL.lastPathComponent,
                location: location,
                contentHash: ContentHasher.sha256NormalizedText(rawText),
                enabled: true,
                loadMode: loadMode,
                payload: .rules(doc),
                diagnostics: importResolution.diagnostics
            )
        ]

        for importedURL in importResolution.resolvedFiles {
            let importedRealPath = fs.resolveSymlinks(importedURL).standardizedFileURL.path
            if primaryRuleRealPaths.contains(importedRealPath) {
                continue
            }
            guard emittedRuleRealPaths.insert(importedRealPath).inserted,
                let importedData = try? fs.contents(at: importedURL),
                let importedText = String(data: importedData, encoding: .utf8)
            else {
                continue
            }

            let importedLocation = AdapterPathNormalizer.sourceLocation(for: importedURL, in: env)
            let importedIdentity = AdapterPathNormalizer.canonicalIdentityPath(for: importedURL, in: env)
            let importedID = ArtifactID(
                agent: .claudeCode,
                kind: .rules,
                scope: scope,
                path: importedIdentity
            )
            let nestedImports = ImportResolver.extractImports(from: importedText).map(\.path)
            let importedDoc = RulesDoc(
                content: importedText,
                imports: nestedImports,
                frontmatter: nil,
                byteCount: importedData.count,
                characterCount: importedText.count,
                wasTruncated: false
            )
            output.append(
                Artifact(
                    id: importedID,
                    agent: .claudeCode,
                    kind: .rules,
                    scope: scope,
                    name: importedURL.lastPathComponent,
                    location: importedLocation,
                    contentHash: ContentHasher.sha256NormalizedText(importedText),
                    enabled: true,
                    loadMode: loadMode,
                    payload: .rules(importedDoc)
                )
            )
        }

        return output
    }

    private static func discoverDirectoryMemoryFiles(
        in directory: URL,
        scope: Scope,
        loadMode: LoadMode,
        includeDotClaudeMemory: Bool,
        primaryRuleRealPaths: Set<String>,
        emittedRuleRealPaths: inout Set<String>,
        env: AgentEnvironment
    ) -> [Artifact] {
        var output: [Artifact] = []
        output.append(
            contentsOf: discoverMemoryFile(
                at: ClaudeCodePathCatalog.memoryFile(in: directory),
                scope: scope,
                loadMode: loadMode,
                primaryRuleRealPaths: primaryRuleRealPaths,
                emittedRuleRealPaths: &emittedRuleRealPaths,
                in: env
            )
        )
        if includeDotClaudeMemory {
            output.append(
                contentsOf: discoverMemoryFile(
                    at: ClaudeCodePathCatalog.dotClaudeMemoryFile(in: directory),
                    scope: scope,
                    loadMode: loadMode,
                    primaryRuleRealPaths: primaryRuleRealPaths,
                    emittedRuleRealPaths: &emittedRuleRealPaths,
                    in: env
                )
            )
        }
        output.append(
            contentsOf: discoverMemoryFile(
                at: ClaudeCodePathCatalog.localMemoryFile(in: directory),
                scope: scope,
                loadMode: loadMode,
                primaryRuleRealPaths: primaryRuleRealPaths,
                emittedRuleRealPaths: &emittedRuleRealPaths,
                in: env
            )
        )
        return output
    }

    private static func discoverDescendantMemoryFiles(
        hierarchy: FolderHierarchy,
        primaryRuleRealPaths: Set<String>,
        emittedRuleRealPaths: inout Set<String>,
        in env: AgentEnvironment
    ) -> [Artifact] {
        let fs = env.fileSystem
        let candidates = AdapterPathNormalizer.collectFilesRecursively(
            under: hierarchy.repoRoot,
            skippingDirectoryNames: ClaudeCodePathCatalog.skippedDescendantDirectoryNames,
            fileSystem: fs
        ) { url in
            url.lastPathComponent == ClaudeCodePathCatalog.memoryFilename
                || url.lastPathComponent == ClaudeCodePathCatalog.localMemoryFilename
        }

        var output: [Artifact] = []
        for fileURL in candidates {
            let realPath = fs.resolveSymlinks(fileURL).standardizedFileURL.path
            if emittedRuleRealPaths.contains(realPath) {
                continue
            }
            let parentDir = fileURL.deletingLastPathComponent().standardizedFileURL
            let relDir =
                AdapterPathNormalizer.relativePath(of: parentDir, from: hierarchy.targetFolder, fileSystem: fs)
                ?? AdapterPathNormalizer.relativePath(of: parentDir, from: hierarchy.repoRoot, fileSystem: fs)
                ?? parentDir.lastPathComponent

            let loadMode: LoadMode =
                relDir.isEmpty
                ? .always
                : .conditional(globs: ["\(relDir)/**"])

            output.append(
                contentsOf: discoverMemoryFile(
                    at: fileURL,
                    scope: .directory,
                    loadMode: loadMode,
                    primaryRuleRealPaths: primaryRuleRealPaths,
                    emittedRuleRealPaths: &emittedRuleRealPaths,
                    in: env
                )
            )
        }
        return output
    }

    private static func discoverModularRules(
        in rulesDir: URL,
        scope: Scope,
        emittedRuleRealPaths: inout Set<String>,
        in env: AgentEnvironment
    ) -> [Artifact] {
        let fs = env.fileSystem
        let ruleFiles = AdapterPathNormalizer.collectFilesRecursively(under: rulesDir, fileSystem: fs) {
            $0.pathExtension.lowercased() == "md"
        }

        var results: [Artifact] = []
        for fileURL in ruleFiles {
            let realPath = fs.resolveSymlinks(fileURL).standardizedFileURL.path
            guard emittedRuleRealPaths.insert(realPath).inserted else {
                continue
            }
            let relName =
                AdapterPathNormalizer.relativePath(of: fileURL, from: rulesDir, fileSystem: fs)
                ?? fileURL.lastPathComponent
            if let artifact = ClaudeCodePayloadParser.parseModularRuleFile(
                at: fileURL,
                relativeName: relName,
                scope: scope,
                in: env
            ) {
                results.append(artifact)
            }
        }
        return results
    }

    // MARK: - Skills, Subagents, Commands

    private static func discoverSkills(
        in skillsRoot: URL,
        scope: Scope,
        parentEnabled: Bool = true,
        in env: AgentEnvironment
    ) -> [Artifact] {
        let fs = env.fileSystem
        guard AdapterPathNormalizer.isEffectiveDirectory(skillsRoot, fileSystem: fs),
            let entries = try? fs.list(skillsRoot)
        else {
            return []
        }

        let sortedDirs = entries.sorted {
            $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8)
        }

        var results: [Artifact] = []
        for entry in sortedDirs where AdapterPathNormalizer.isEffectiveDirectory(entry, fileSystem: fs) {
            let manifestURL = ClaudeCodePathCatalog.skillManifestFile(in: entry)
            guard AdapterPathNormalizer.isEffectiveFile(manifestURL, fileSystem: fs) else {
                continue
            }
            if let artifact = ClaudeCodePayloadParser.parseSkillDirectory(
                entry,
                manifestURL: manifestURL,
                scope: scope,
                parentEnabled: parentEnabled,
                in: env
            ) {
                results.append(artifact)
            }
        }
        return results
    }

    private static func discoverSubagents(
        in agentsRoot: URL,
        scope: Scope,
        parentEnabled: Bool = true,
        in env: AgentEnvironment
    ) -> [Artifact] {
        let files = AdapterPathNormalizer.collectFilesRecursively(under: agentsRoot, fileSystem: env.fileSystem) {
            $0.pathExtension.lowercased() == "md"
        }
        return files.compactMap { fileURL in
            ClaudeCodePayloadParser.parseSubagentFile(
                at: fileURL,
                scope: scope,
                parentEnabled: parentEnabled,
                in: env
            )
        }
    }

    private static func discoverCommands(
        in commandsRoot: URL,
        scope: Scope,
        parentEnabled: Bool = true,
        in env: AgentEnvironment
    ) -> [Artifact] {
        let files = AdapterPathNormalizer.collectFilesRecursively(under: commandsRoot, fileSystem: env.fileSystem) {
            $0.pathExtension.lowercased() == "md"
        }
        return files.compactMap { fileURL in
            ClaudeCodePayloadParser.parseCommandFile(
                at: fileURL,
                commandsRoot: commandsRoot,
                scope: scope,
                parentEnabled: parentEnabled,
                in: env
            )
        }
    }

    // MARK: - Plugins

    private static func discoverPlugins(
        settingsPrecedenceTrees: [[String: JSONValue]],
        in env: AgentEnvironment
    ) -> [Artifact] {
        let fs = env.fileSystem
        let cacheRoot = ClaudeCodePathCatalog.userPluginsCacheDirectory(in: env)
        guard AdapterPathNormalizer.isEffectiveDirectory(cacheRoot, fileSystem: fs) else {
            return []
        }

        let installedSelections = parseInstalledPluginsRegistry(in: env)
        let manifestURLs = AdapterPathNormalizer.collectFilesRecursively(under: cacheRoot, fileSystem: fs) {
            ClaudeCodePathCatalog.isPluginManifestURL($0)
        }

        var groupedCandidates: [String: [PluginCandidate]] = [:]
        for manifestURL in manifestURLs {
            let pluginDir = ClaudeCodePathCatalog.pluginRootDirectory(forManifestURL: manifestURL)
            let rel =
                AdapterPathNormalizer.relativePath(of: pluginDir, from: cacheRoot, fileSystem: fs)
                ?? pluginDir.lastPathComponent
            let parts = rel.split(separator: "/").map(String.init)

            let candidate: PluginCandidate
            if parts.count >= 3 {
                let marketplace = parts[0]
                let name = parts[1]
                let version = parts[2]
                candidate = PluginCandidate(
                    pluginKey: "\(name)@\(marketplace)",
                    shortName: name,
                    dirVersion: version,
                    pluginDir: pluginDir,
                    manifestURL: manifestURL
                )
            } else if parts.count == 2 {
                let name = parts[0]
                let version = parts[1]
                candidate = PluginCandidate(
                    pluginKey: name,
                    shortName: name,
                    dirVersion: version,
                    pluginDir: pluginDir,
                    manifestURL: manifestURL
                )
            } else {
                let name = parts.first ?? pluginDir.lastPathComponent
                candidate = PluginCandidate(
                    pluginKey: name,
                    shortName: name,
                    dirVersion: "",
                    pluginDir: pluginDir,
                    manifestURL: manifestURL
                )
            }
            groupedCandidates[candidate.pluginKey, default: []].append(candidate)
        }

        var output: [Artifact] = []

        for pluginKey in groupedCandidates.keys.sorted() {
            guard let candidates = groupedCandidates[pluginKey],
                let selected = selectActivePluginCandidate(
                    from: candidates,
                    pluginKey: pluginKey,
                    selections: installedSelections,
                    fileSystem: fs
                )
            else {
                continue
            }

            output.append(
                contentsOf: loadPluginBundle(
                    selected,
                    settingsPrecedenceTrees: settingsPrecedenceTrees,
                    in: env
                )
            )
        }

        return output
    }

    private static func parseInstalledPluginsRegistry(
        in env: AgentEnvironment
    ) -> [String: InstalledPluginSelection] {
        let registryURL = ClaudeCodePathCatalog.userPluginsRegistryFile(in: env)
        guard AdapterPathNormalizer.isEffectiveFile(registryURL, fileSystem: env.fileSystem),
            let rawData = try? env.fileSystem.contents(at: registryURL),
            let tree = try? JSONCParser.parseObject(rawData)
        else {
            return [:]
        }

        let entriesMap: [String: JSONValue]
        if case .object(let pluginsObj) = tree["plugins"] {
            entriesMap = pluginsObj
        } else {
            entriesMap = tree
        }

        var selections: [String: InstalledPluginSelection] = [:]
        for key in entriesMap.keys.sorted() {
            let recordDict: [String: JSONValue]?
            switch entriesMap[key] {
            case .array(let list):
                recordDict =
                    list.compactMap { item -> [String: JSONValue]? in
                        if case .object(let obj) = item { return obj }
                        return nil
                    }.first
            case .object(let obj):
                recordDict = obj
            default:
                recordDict = nil
            }

            guard let recordDict else { continue }
            let version = ClaudeCodePayloadParser.nonEmptyString(recordDict["version"])
            let installURL = ClaudeCodePayloadParser.nonEmptyString(recordDict["installPath"]).map {
                AdapterPathNormalizer.expandHomePrefix($0, in: env)
            }
            selections[key] = InstalledPluginSelection(installURL: installURL, version: version)
        }

        return selections
    }

    private static func selectActivePluginCandidate(
        from candidates: [PluginCandidate],
        pluginKey: String,
        selections: [String: InstalledPluginSelection],
        fileSystem: any ReadOnlyFileSystem
    ) -> PluginCandidate? {
        guard !candidates.isEmpty else { return nil }
        let selection = selections[pluginKey] ?? candidates.first.flatMap { selections[$0.shortName] }

        if let targetURL = selection?.installURL {
            let targetStd = targetURL.standardizedFileURL.path
            let targetReal = fileSystem.resolveSymlinks(targetURL).standardizedFileURL.path
            if let matchedByPath = candidates.first(where: {
                $0.pluginDir.standardizedFileURL.path == targetStd
                    || fileSystem.resolveSymlinks($0.pluginDir).standardizedFileURL.path == targetReal
            }) {
                return matchedByPath
            }
        }

        if let targetVersion = selection?.version,
            let matchedByVersion = candidates.first(where: { $0.dirVersion == targetVersion })
        {
            return matchedByVersion
        }

        return candidates.max { lhs, rhs in
            let cmp = compareVersionStrings(lhs.dirVersion, rhs.dirVersion)
            if cmp != 0 {
                return cmp < 0
            }
            return lhs.pluginDir.path < rhs.pluginDir.path
        }
    }

    private static func loadPluginBundle(
        _ candidate: PluginCandidate,
        settingsPrecedenceTrees: [[String: JSONValue]],
        in env: AgentEnvironment
    ) -> [Artifact] {
        let fs = env.fileSystem
        let manifestURL = candidate.manifestURL
        let location = AdapterPathNormalizer.sourceLocation(for: manifestURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: manifestURL, in: env)
        let pluginArtifactID = ArtifactID(
            agent: .claudeCode,
            kind: .plugin,
            scope: .user,
            path: identityPath
        )

        guard let rawData = try? fs.contents(at: manifestURL) else {
            return []
        }

        let contentHash = ClaudeCodePayloadParser.hashData(rawData)
        let (parsedDoc, diagnostics) = JSONCParser.parseSettings(rawData, location: location)

        guard let tree = parsedDoc?.tree else {
            return [
                Artifact(
                    id: pluginArtifactID,
                    agent: .claudeCode,
                    kind: .plugin,
                    scope: .user,
                    name: candidate.shortName,
                    location: location,
                    contentHash: contentHash,
                    enabled: false,
                    loadMode: .never,
                    payload: .other,
                    diagnostics: diagnostics
                )
            ]
        }

        let manifestName = ClaudeCodePayloadParser.nonEmptyString(tree["name"]) ?? candidate.shortName
        let version =
            ClaudeCodePayloadParser.nonEmptyString(tree["version"])
            ?? (candidate.dirVersion.isEmpty ? nil : candidate.dirVersion)
        let description = ClaudeCodePayloadParser.nonEmptyString(tree["description"])

        let isEnabled = resolvePluginEnabled(
            pluginKey: candidate.pluginKey,
            shortName: manifestName,
            settingsPrecedenceTrees: settingsPrecedenceTrees
        )

        let skills = discoverSkills(
            in: ClaudeCodePathCatalog.pluginSkillsDirectory(in: candidate.pluginDir),
            scope: .user,
            parentEnabled: isEnabled,
            in: env
        )
        let subagents = discoverSubagents(
            in: ClaudeCodePathCatalog.pluginAgentsDirectory(in: candidate.pluginDir),
            scope: .user,
            parentEnabled: isEnabled,
            in: env
        )
        let commands = discoverCommands(
            in: ClaudeCodePathCatalog.pluginCommandsDirectory(in: candidate.pluginDir),
            scope: .user,
            parentEnabled: isEnabled,
            in: env
        )

        var hooks: [Artifact] = []
        let hooksFile = ClaudeCodePathCatalog.pluginHooksFile(in: candidate.pluginDir)
        if AdapterPathNormalizer.isEffectiveFile(hooksFile, fileSystem: fs) {
            hooks.append(
                contentsOf: ClaudeCodePayloadParser.parseStandaloneHooksFile(
                    at: hooksFile,
                    scope: .user,
                    enabled: isEnabled,
                    in: env
                )
            )
        }
        hooks.append(
            contentsOf: ClaudeCodePayloadParser.extractHooks(
                from: tree,
                fileURL: manifestURL,
                scope: .user,
                enabled: isEnabled,
                contentHash: contentHash,
                in: env
            )
        )

        var mcpServers: [Artifact] = []
        let pluginMCPFile = ClaudeCodePathCatalog.pluginMCPFile(in: candidate.pluginDir)
        if AdapterPathNormalizer.isEffectiveFile(pluginMCPFile, fileSystem: fs) {
            mcpServers.append(
                contentsOf: ClaudeCodePayloadParser.parseMCPFile(
                    at: pluginMCPFile,
                    scope: .user,
                    parentEnabled: isEnabled,
                    in: env
                )
            )
        }
        if case .object(let inlineMCP) = tree["mcpServers"] {
            mcpServers.append(
                contentsOf: ClaudeCodePayloadParser.parseMCPServersDictionary(
                    inlineMCP,
                    keyPrefix: ["mcpServers"],
                    fileURL: manifestURL,
                    scope: .user,
                    parentEnabled: isEnabled,
                    contentHash: contentHash,
                    in: env
                )
            )
        }

        let manifest = PluginManifest(
            name: manifestName,
            version: version,
            description: description,
            skills: skills.map(\.name).sorted(),
            agents: subagents.map(\.name).sorted(),
            commands: commands.map(\.name).sorted(),
            mcpServers: mcpServers.map(\.name).sorted()
        )

        let pluginArtifact = Artifact(
            id: pluginArtifactID,
            agent: .claudeCode,
            kind: .plugin,
            scope: .user,
            name: manifestName,
            location: location,
            contentHash: contentHash,
            enabled: isEnabled,
            loadMode: .never,
            payload: .plugin(manifest),
            diagnostics: diagnostics
        )

        var bundle: [Artifact] = [pluginArtifact]
        bundle.append(contentsOf: skills)
        bundle.append(contentsOf: subagents)
        bundle.append(contentsOf: commands)
        bundle.append(contentsOf: hooks)
        bundle.append(contentsOf: mcpServers)
        return bundle
    }

    private static func resolvePluginEnabled(
        pluginKey: String,
        shortName: String,
        settingsPrecedenceTrees: [[String: JSONValue]]
    ) -> Bool {
        for tree in settingsPrecedenceTrees {
            guard case .object(let enabledMap) = tree["enabledPlugins"] else {
                continue
            }
            if let explicit = ClaudeCodePayloadParser.boolValue(enabledMap[pluginKey]) {
                return explicit
            }
            if let byShortName = ClaudeCodePayloadParser.boolValue(enabledMap[shortName]) {
                return byShortName
            }
        }
        return true
    }

    private static func compareVersionStrings(_ lhs: String, _ rhs: String) -> Int {
        let lhsParts = lhs.split(separator: ".")
        let rhsParts = rhs.split(separator: ".")
        let count = max(lhsParts.count, rhsParts.count)
        for idx in 0..<count {
            let lToken = idx < lhsParts.count ? String(lhsParts[idx]) : "0"
            let rToken = idx < rhsParts.count ? String(rhsParts[idx]) : "0"
            if let lInt = Int(lToken), let rInt = Int(rToken) {
                if lInt != rInt {
                    return lInt < rInt ? -1 : 1
                }
            } else if lToken != rToken {
                return lToken < rToken ? -1 : 1
            }
        }
        return 0
    }
}
