import BentoCore
import BentoParsing
import Foundation

/// Read-only filesystem discovery engine for Google Gemini CLI across system-managed, system-default,
/// user, extension, workspace, and nested directory scopes.
enum GeminiDiscovery {
    struct FolderHierarchy {
        let ancestorsAboveRepo: [URL]
        let repoRoot: URL
        let ancestorsInsideRepoToTarget: [URL]
        let targetFolder: URL
    }

    struct EffectiveSettingsSummary {
        var contextFileNames: [String] = [GeminiPathCatalog.defaultContextFilename]
        var mcpExcluded: Set<String> = []
        var mcpAllowed: Set<String>?
        var disabledExtensions: Set<String> = []
        var disabledSubagents: Set<String> = []
    }

    /// Discovers all Gemini CLI artifacts at global scope and, when `folder` is provided, workspace scope.
    static func discover(in env: AgentEnvironment, folder: URL?) -> [Artifact] {
        let fs = env.fileSystem
        let hierarchy = resolveFolderHierarchy(for: folder, in: env)

        // 1. Pre-parse the 4 settings tiers: managed (system) > project (workspace) > user > builtIn (system-defaults)
        let managedSettingsURL = GeminiPathCatalog.managedSettingsFile(in: env)
        let systemDefaultsURL = GeminiPathCatalog.systemDefaultsFile(in: env)
        let userSettingsURL = GeminiPathCatalog.userSettingsFile(in: env)

        let managedParsed =
            AdapterPathNormalizer.isEffectiveFile(managedSettingsURL, fileSystem: fs)
            ? GeminiPayloadParser.parseSettingsFile(at: managedSettingsURL, scope: .managed, in: env)
            : nil
        let systemDefaultsParsed =
            AdapterPathNormalizer.isEffectiveFile(systemDefaultsURL, fileSystem: fs)
            ? GeminiPayloadParser.parseSettingsFile(at: systemDefaultsURL, scope: .builtIn, in: env)
            : nil
        let userParsed =
            AdapterPathNormalizer.isEffectiveFile(userSettingsURL, fileSystem: fs)
            ? GeminiPayloadParser.parseSettingsFile(at: userSettingsURL, scope: .user, in: env)
            : nil

        var projectParsed: GeminiPayloadParser.ParsedSettingsConfig?
        if let hierarchy {
            let projSettingsURL = GeminiPathCatalog.directorySettingsFile(in: hierarchy.repoRoot)
            if AdapterPathNormalizer.isEffectiveFile(projSettingsURL, fileSystem: fs) {
                projectParsed = GeminiPayloadParser.parseSettingsFile(
                    at: projSettingsURL,
                    scope: .project,
                    in: env
                )
            }
        }

        // Highest -> lowest precedence trees
        var precedenceTrees: [[String: JSONValue]] = []
        if let tree = managedParsed?.parsedTree { precedenceTrees.append(tree) }
        if let tree = projectParsed?.parsedTree { precedenceTrees.append(tree) }
        if let tree = userParsed?.parsedTree { precedenceTrees.append(tree) }
        if let tree = systemDefaultsParsed?.parsedTree { precedenceTrees.append(tree) }

        let summary = buildEffectiveSettingsSummary(precedenceTrees: precedenceTrees)

        // Pre-compute primary context file real paths so @import expansion never duplicates standalone rule files
        let primaryRuleRealPaths = collectPrimaryContextRealPaths(
            contextFileNames: summary.contextFileNames,
            hierarchy: hierarchy,
            in: env
        )
        var emittedRuleRealPaths: Set<String> = []

        var artifacts: [Artifact] = []

        // 2. System defaults (builtIn) & System override (managed)
        if let systemDefaultsParsed {
            artifacts.append(systemDefaultsParsed.settingsArtifact)
            artifacts.append(contentsOf: systemDefaultsParsed.mcpArtifacts)
            artifacts.append(contentsOf: systemDefaultsParsed.hookArtifacts)
        }
        if let managedParsed {
            artifacts.append(managedParsed.settingsArtifact)
            artifacts.append(contentsOf: managedParsed.mcpArtifacts)
            artifacts.append(contentsOf: managedParsed.hookArtifacts)
        }

        // 3. User scope
        if let userParsed {
            artifacts.append(userParsed.settingsArtifact)
            artifacts.append(contentsOf: userParsed.mcpArtifacts)
            artifacts.append(contentsOf: userParsed.hookArtifacts)
        }

        let userGeminiDir = GeminiPathCatalog.userGeminiDirectory(in: env)
        for contextName in summary.contextFileNames {
            let userContextURL = userGeminiDir.appendingPathComponent(contextName).standardizedFileURL
            artifacts.append(
                contentsOf: discoverContextFile(
                    at: userContextURL,
                    scope: .user,
                    enabled: true,
                    loadMode: .always,
                    primaryRuleRealPaths: primaryRuleRealPaths,
                    emittedRuleRealPaths: &emittedRuleRealPaths,
                    in: env
                )
            )
        }

        artifacts.append(
            contentsOf: discoverSkills(
                in: GeminiPathCatalog.userAgentsSkillsDirectory(in: env),
                scope: .user,
                enabled: true,
                in: env
            )
        )
        artifacts.append(
            contentsOf: discoverSkills(
                in: GeminiPathCatalog.userGeminiSkillsDirectory(in: env),
                scope: .user,
                enabled: true,
                in: env
            )
        )
        artifacts.append(
            contentsOf: discoverSubagents(
                in: GeminiPathCatalog.userSubagentsDirectory(in: env),
                scope: .user,
                parentEnabled: true,
                disabledSubagents: summary.disabledSubagents,
                in: env
            )
        )
        artifacts.append(
            contentsOf: discoverCommands(
                in: GeminiPathCatalog.userCommandsDirectory(in: env),
                scope: .user,
                enabled: true,
                in: env
            )
        )

        // 4. Installed Gemini CLI Extensions (`~/.gemini/extensions/*`)
        artifacts.append(
            contentsOf: discoverExtensions(
                summary: summary,
                targetFolder: hierarchy?.targetFolder,
                primaryRuleRealPaths: primaryRuleRealPaths,
                emittedRuleRealPaths: &emittedRuleRealPaths,
                in: env
            )
        )

        // 5. Workspace / Project & Directory scopes
        if let hierarchy {
            let repoRoot = hierarchy.repoRoot

            if let projectParsed {
                artifacts.append(projectParsed.settingsArtifact)
                artifacts.append(contentsOf: projectParsed.mcpArtifacts)
                artifacts.append(contentsOf: projectParsed.hookArtifacts)
            }

            let ignoreURL = GeminiPathCatalog.directoryIgnoreFile(in: repoRoot)
            if AdapterPathNormalizer.isEffectiveFile(ignoreURL, fileSystem: fs),
                let ignoreArtifact = GeminiPayloadParser.parseIgnoreFile(at: ignoreURL, scope: .project, in: env)
            {
                artifacts.append(ignoreArtifact)
            }

            for ancestorDir in hierarchy.ancestorsAboveRepo {
                for contextName in summary.contextFileNames {
                    let fileURL = ancestorDir.appendingPathComponent(contextName).standardizedFileURL
                    artifacts.append(
                        contentsOf: discoverContextFile(
                            at: fileURL,
                            scope: .directory,
                            enabled: true,
                            loadMode: .always,
                            primaryRuleRealPaths: primaryRuleRealPaths,
                            emittedRuleRealPaths: &emittedRuleRealPaths,
                            in: env
                        )
                    )
                }
            }

            for contextName in summary.contextFileNames {
                let repoContextURL = repoRoot.appendingPathComponent(contextName).standardizedFileURL
                artifacts.append(
                    contentsOf: discoverContextFile(
                        at: repoContextURL,
                        scope: .project,
                        enabled: true,
                        loadMode: .always,
                        primaryRuleRealPaths: primaryRuleRealPaths,
                        emittedRuleRealPaths: &emittedRuleRealPaths,
                        in: env
                    )
                )
            }

            artifacts.append(
                contentsOf: discoverSkills(
                    in: GeminiPathCatalog.directoryAgentsSkillsDirectory(in: repoRoot),
                    scope: .project,
                    enabled: true,
                    in: env
                )
            )
            artifacts.append(
                contentsOf: discoverSkills(
                    in: GeminiPathCatalog.directoryGeminiSkillsDirectory(in: repoRoot),
                    scope: .project,
                    enabled: true,
                    in: env
                )
            )
            artifacts.append(
                contentsOf: discoverSubagents(
                    in: GeminiPathCatalog.directorySubagentsDirectory(in: repoRoot),
                    scope: .project,
                    parentEnabled: true,
                    disabledSubagents: summary.disabledSubagents,
                    in: env
                )
            )
            artifacts.append(
                contentsOf: discoverCommands(
                    in: GeminiPathCatalog.directoryCommandsDirectory(in: repoRoot),
                    scope: .project,
                    enabled: true,
                    in: env
                )
            )

            for subdir in hierarchy.ancestorsInsideRepoToTarget {
                for contextName in summary.contextFileNames {
                    let subdirContextURL = subdir.appendingPathComponent(contextName).standardizedFileURL
                    artifacts.append(
                        contentsOf: discoverContextFile(
                            at: subdirContextURL,
                            scope: .directory,
                            enabled: true,
                            loadMode: .always,
                            primaryRuleRealPaths: primaryRuleRealPaths,
                            emittedRuleRealPaths: &emittedRuleRealPaths,
                            in: env
                        )
                    )
                }
            }

            artifacts.append(
                contentsOf: discoverDescendantContextFiles(
                    hierarchy: hierarchy,
                    contextFileNames: summary.contextFileNames,
                    primaryRuleRealPaths: primaryRuleRealPaths,
                    emittedRuleRealPaths: &emittedRuleRealPaths,
                    in: env
                )
            )
        }

        return artifacts
    }

    // MARK: - Folder Hierarchy

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
                if GeminiPathCatalog.hasGitMarker(in: cursor, fileSystem: fs) {
                    break
                }
                let parent = cursor.deletingLastPathComponent().standardizedFileURL
                if parent.path == cursor.path || parent.path == "/" {
                    break
                }
                cursor = parent
            }
            if let gitRootIndex = upward.firstIndex(where: { GeminiPathCatalog.hasGitMarker(in: $0, fileSystem: fs) }) {
                chain = Array(upward[0...gitRootIndex].reversed())
            } else {
                chain = [targetFolder]
            }
        }

        guard !chain.isEmpty else { return nil }

        let repoIndex: Int
        if let nearestGitIdx = chain.lastIndex(where: { GeminiPathCatalog.hasGitMarker(in: $0, fileSystem: fs) }) {
            repoIndex = nearestGitIdx
        } else if let outermostIdx = chain.firstIndex(where: {
            GeminiPathCatalog.hasGeminiRootMarkers(in: $0, fileSystem: fs)
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

    // MARK: - Effective Settings Summary

    static func buildEffectiveSettingsSummary(
        precedenceTrees: [[String: JSONValue]]
    ) -> EffectiveSettingsSummary {
        var summary = EffectiveSettingsSummary()

        // Highest-precedence settings tier defining `context.fileName` wins
        for tree in precedenceTrees {
            if case .object(let contextObj) = tree["context"],
                let names = GeminiPayloadParser.stringOrArray(contextObj["fileName"])
            {
                let sanitized = names.filter { !$0.contains("/") }
                if !sanitized.isEmpty {
                    summary.contextFileNames = sanitized
                    break
                }
            }
        }

        // Merge `mcp.excluded`, `mcp.allowed`, `extensions.disabled`, and `agents.overrides` from base -> override
        for tree in precedenceTrees.reversed() {
            if case .object(let mcpObj) = tree["mcp"] {
                if let excluded = GeminiPayloadParser.stringArray(mcpObj["excluded"]) {
                    summary.mcpExcluded.formUnion(excluded)
                }
                if let allowed = GeminiPayloadParser.stringArray(mcpObj["allowed"]), !allowed.isEmpty {
                    if let existing = summary.mcpAllowed {
                        summary.mcpAllowed = existing.intersection(allowed)
                    } else {
                        summary.mcpAllowed = Set(allowed)
                    }
                }
            }

            if case .object(let extObj) = tree["extensions"],
                let disabledList = GeminiPayloadParser.stringArray(extObj["disabled"])
            {
                summary.disabledExtensions.formUnion(disabledList)
            }

            if case .object(let agentsObj) = tree["agents"],
                case .object(let overridesObj) = agentsObj["overrides"]
            {
                for (agentName, val) in overridesObj {
                    guard case .object(let overrideDict) = val else { continue }
                    if GeminiPayloadParser.boolValue(overrideDict["enabled"]) == false {
                        summary.disabledSubagents.insert(agentName)
                    } else if GeminiPayloadParser.boolValue(overrideDict["enabled"]) == true {
                        summary.disabledSubagents.remove(agentName)
                    }
                }
            }
        }

        return summary
    }

    // MARK: - Context / Memory Files (`GEMINI.md`, `context.fileName`, `@imports`)

    private static func collectPrimaryContextRealPaths(
        contextFileNames: [String],
        hierarchy: FolderHierarchy?,
        in env: AgentEnvironment
    ) -> Set<String> {
        let fs = env.fileSystem
        let nameSet = Set(contextFileNames)
        var candidates: [URL] = []

        let userGeminiDir = GeminiPathCatalog.userGeminiDirectory(in: env)
        for name in contextFileNames {
            candidates.append(userGeminiDir.appendingPathComponent(name))
        }

        let extensionsRoot = GeminiPathCatalog.userExtensionsDirectory(in: env)
        if AdapterPathNormalizer.isEffectiveDirectory(extensionsRoot, fileSystem: fs),
            let extDirs = try? fs.list(extensionsRoot)
        {
            for extDir in extDirs where AdapterPathNormalizer.isEffectiveDirectory(extDir, fileSystem: fs) {
                let manifestURL = GeminiPathCatalog.extensionManifestFile(in: extDir)
                var extContextNames = [GeminiPathCatalog.defaultContextFilename]
                if let data = try? fs.contents(at: manifestURL),
                    let tree = JSONCParser.parseSettings(data).settings?.tree,
                    let configured = GeminiPayloadParser.stringOrArray(tree["contextFileName"])
                {
                    extContextNames = configured
                }
                for name in extContextNames {
                    candidates.append(extDir.appendingPathComponent(name))
                }
            }
        }

        if let hierarchy {
            let dirs = [hierarchy.repoRoot] + hierarchy.ancestorsAboveRepo + hierarchy.ancestorsInsideRepoToTarget
            for dir in dirs {
                for name in contextFileNames {
                    candidates.append(dir.appendingPathComponent(name))
                }
            }
            candidates.append(
                contentsOf: AdapterPathNormalizer.collectFilesRecursively(
                    under: hierarchy.repoRoot,
                    skippingDirectoryNames: GeminiPathCatalog.skippedDescendantDirectoryNames,
                    fileSystem: fs
                ) { nameSet.contains($0.lastPathComponent) }
            )
        }

        var realPaths: Set<String> = []
        for url in candidates where AdapterPathNormalizer.isEffectiveFile(url, fileSystem: fs) {
            realPaths.insert(fs.resolveSymlinks(url).standardizedFileURL.path)
        }
        return realPaths
    }

    private static func discoverContextFile(
        at fileURL: URL,
        scope: Scope,
        enabled: Bool,
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
        let id = ArtifactID(agent: .gemini, kind: .rules, scope: scope, path: identityPath)

        guard let rawText = String(data: rawData, encoding: .utf8) else {
            let diag = Diagnostic(
                code: "rules.invalidUTF8",
                severity: .warning,
                message: "Gemini context file '\(fileURL.lastPathComponent)' is not valid UTF-8",
                location: location
            )
            return [
                Artifact(
                    id: id,
                    agent: .gemini,
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

        let importResolution = ImportResolver(syntax: .gemini).resolve(
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

        let effectiveMode: LoadMode = enabled ? loadMode : .never
        var output: [Artifact] = [
            Artifact(
                id: id,
                agent: .gemini,
                kind: .rules,
                scope: scope,
                name: fileURL.lastPathComponent,
                location: location,
                contentHash: ContentHasher.sha256NormalizedText(rawText),
                enabled: enabled,
                loadMode: effectiveMode,
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
                agent: .gemini,
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
                    agent: .gemini,
                    kind: .rules,
                    scope: scope,
                    name: importedURL.lastPathComponent,
                    location: importedLocation,
                    contentHash: ContentHasher.sha256NormalizedText(importedText),
                    enabled: enabled,
                    loadMode: effectiveMode,
                    payload: .rules(importedDoc)
                )
            )
        }

        return output
    }

    private static func discoverDescendantContextFiles(
        hierarchy: FolderHierarchy,
        contextFileNames: [String],
        primaryRuleRealPaths: Set<String>,
        emittedRuleRealPaths: inout Set<String>,
        in env: AgentEnvironment
    ) -> [Artifact] {
        let fs = env.fileSystem
        let nameSet = Set(contextFileNames)
        let targetStdPath = hierarchy.targetFolder.standardizedFileURL.path

        let files = AdapterPathNormalizer.collectFilesRecursively(
            under: hierarchy.targetFolder,
            skippingDirectoryNames: GeminiPathCatalog.skippedDescendantDirectoryNames,
            fileSystem: fs
        ) { url in
            let parentPath = url.deletingLastPathComponent().standardizedFileURL.path
            return parentPath != targetStdPath && nameSet.contains(url.lastPathComponent)
        }

        var dirsInOrder: [URL] = []
        var seenDirs: Set<String> = []
        for fileURL in files {
            let dir = fileURL.deletingLastPathComponent().standardizedFileURL
            if seenDirs.insert(dir.path).inserted {
                dirsInOrder.append(dir)
            }
        }

        var output: [Artifact] = []
        for dir in dirsInOrder {
            let relDir =
                AdapterPathNormalizer.relativePath(of: dir, from: hierarchy.targetFolder, fileSystem: fs)
                ?? dir.lastPathComponent
            let loadMode: LoadMode = relDir.isEmpty ? .always : .conditional(globs: ["\(relDir)/**"])

            for contextName in contextFileNames {
                let candidate = dir.appendingPathComponent(contextName).standardizedFileURL
                output.append(
                    contentsOf: discoverContextFile(
                        at: candidate,
                        scope: .directory,
                        enabled: true,
                        loadMode: loadMode,
                        primaryRuleRealPaths: primaryRuleRealPaths,
                        emittedRuleRealPaths: &emittedRuleRealPaths,
                        in: env
                    )
                )
            }
        }

        return output
    }

    // MARK: - Skills, Subagents & Commands

    private static func discoverSkills(
        in skillsRoot: URL,
        scope: Scope,
        enabled: Bool,
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
        for entry in sortedDirs {
            guard AdapterPathNormalizer.isEffectiveDirectory(entry, fileSystem: fs) else {
                continue
            }
            let manifestURL = entry.appendingPathComponent(GeminiPathCatalog.skillManifestFilename)
            guard AdapterPathNormalizer.isEffectiveFile(manifestURL, fileSystem: fs) else {
                continue
            }
            results.append(
                GeminiPayloadParser.parseSkill(
                    skillDirectory: entry,
                    manifestURL: manifestURL,
                    scope: scope,
                    enabled: enabled,
                    in: env
                )
            )
        }

        return results
    }

    private static func discoverSubagents(
        in agentsRoot: URL,
        scope: Scope,
        parentEnabled: Bool,
        disabledSubagents: Set<String>,
        in env: AgentEnvironment
    ) -> [Artifact] {
        let fs = env.fileSystem
        let files = AdapterPathNormalizer.collectFilesRecursively(
            under: agentsRoot,
            fileSystem: fs
        ) { $0.pathExtension.lowercased() == GeminiPathCatalog.markdownFileExtension }

        var results: [Artifact] = []
        for fileURL in files {
            let fallbackName = fileURL.deletingPathExtension().lastPathComponent
            let preCheckEnabled = parentEnabled && !disabledSubagents.contains(fallbackName)
            guard
                var artifact = GeminiPayloadParser.parseSubagentFile(
                    at: fileURL,
                    scope: scope,
                    enabled: preCheckEnabled,
                    in: env
                )
            else {
                continue
            }
            if disabledSubagents.contains(artifact.name) {
                artifact.enabled = false
                artifact.loadMode = .never
            }
            results.append(artifact)
        }

        return results
    }

    private static func discoverCommands(
        in commandsRoot: URL,
        scope: Scope,
        enabled: Bool,
        in env: AgentEnvironment
    ) -> [Artifact] {
        let fs = env.fileSystem
        let files = AdapterPathNormalizer.collectFilesRecursively(
            under: commandsRoot,
            fileSystem: fs
        ) { $0.pathExtension.lowercased() == GeminiPathCatalog.commandFileExtension }

        return files.compactMap { fileURL in
            GeminiPayloadParser.parseCommandFile(
                at: fileURL,
                commandsRoot: commandsRoot,
                scope: scope,
                enabled: enabled,
                in: env
            )
        }
    }

    // MARK: - Extensions (`~/.gemini/extensions/*`)

    private static func discoverExtensions(
        summary: EffectiveSettingsSummary,
        targetFolder: URL?,
        primaryRuleRealPaths: Set<String>,
        emittedRuleRealPaths: inout Set<String>,
        in env: AgentEnvironment
    ) -> [Artifact] {
        let fs = env.fileSystem
        let extensionsRoot = GeminiPathCatalog.userExtensionsDirectory(in: env)
        guard AdapterPathNormalizer.isEffectiveDirectory(extensionsRoot, fileSystem: fs),
            let entries = try? fs.list(extensionsRoot)
        else {
            return []
        }

        let enablementURL = GeminiPathCatalog.extensionEnablementFile(in: env)
        let enablementTree: [String: JSONValue]? =
            if AdapterPathNormalizer.isEffectiveFile(enablementURL, fileSystem: fs),
                let data = try? fs.contents(at: enablementURL)
            {
                JSONCParser.parseSettings(data).settings?.tree
            } else {
                nil
            }

        let sortedDirs = entries.sorted {
            $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8)
        }

        var results: [Artifact] = []
        for extDir in sortedDirs {
            guard AdapterPathNormalizer.isEffectiveDirectory(extDir, fileSystem: fs) else {
                continue
            }
            let manifestURL = GeminiPathCatalog.extensionManifestFile(in: extDir)
            guard AdapterPathNormalizer.isEffectiveFile(manifestURL, fileSystem: fs),
                let rawData = try? fs.contents(at: manifestURL)
            else {
                continue
            }

            let manifestLocation = AdapterPathNormalizer.sourceLocation(for: manifestURL, in: env)
            let manifestIdentity = AdapterPathNormalizer.canonicalIdentityPath(for: manifestURL, in: env)
            let pluginID = ArtifactID(
                agent: .gemini,
                kind: .plugin,
                scope: .user,
                path: manifestIdentity
            )
            let contentHash = GeminiPayloadParser.hashData(rawData)
            let (parsedDoc, diagnostics) = JSONCParser.parseSettings(rawData, location: manifestLocation)

            guard let tree = parsedDoc?.tree else {
                results.append(
                    Artifact(
                        id: pluginID,
                        agent: .gemini,
                        kind: .plugin,
                        scope: .user,
                        name: extDir.lastPathComponent,
                        location: manifestLocation,
                        contentHash: contentHash,
                        enabled: false,
                        loadMode: .never,
                        payload: .other,
                        diagnostics: diagnostics
                    )
                )
                continue
            }

            let extName = GeminiPayloadParser.nonEmptyString(tree["name"]) ?? extDir.lastPathComponent
            let extVersion = GeminiPayloadParser.nonEmptyString(tree["version"])
            let extDescription = GeminiPayloadParser.nonEmptyString(tree["description"])
            let isEnabled = isExtensionEnabled(
                name: extName,
                directoryName: extDir.lastPathComponent,
                enablementTree: enablementTree,
                disabledExtensions: summary.disabledExtensions,
                targetFolder: targetFolder
            )

            var extMCPArtifacts: [Artifact] = []
            if case .object(let serversMap) = tree["mcpServers"] {
                extMCPArtifacts = GeminiPayloadParser.parseMCPServersDictionary(
                    serversMap,
                    keyPrefix: ["mcpServers"],
                    fileURL: manifestURL,
                    scope: .user,
                    parentEnabled: isEnabled,
                    contentHash: contentHash,
                    in: env
                )
            }

            let extContextNames =
                GeminiPayloadParser.stringOrArray(tree["contextFileName"])
                ?? [GeminiPathCatalog.defaultContextFilename]
            var extContextArtifacts: [Artifact] = []
            for contextName in extContextNames where !contextName.contains("/") {
                let contextURL = extDir.appendingPathComponent(contextName).standardizedFileURL
                extContextArtifacts.append(
                    contentsOf: discoverContextFile(
                        at: contextURL,
                        scope: .user,
                        enabled: isEnabled,
                        loadMode: .always,
                        primaryRuleRealPaths: primaryRuleRealPaths,
                        emittedRuleRealPaths: &emittedRuleRealPaths,
                        in: env
                    )
                )
            }

            let extSkillArtifacts = discoverSkills(
                in: GeminiPathCatalog.extensionSkillsDirectory(in: extDir),
                scope: .user,
                enabled: isEnabled,
                in: env
            )
            let extSubagentArtifacts = discoverSubagents(
                in: GeminiPathCatalog.extensionSubagentsDirectory(in: extDir),
                scope: .user,
                parentEnabled: isEnabled,
                disabledSubagents: summary.disabledSubagents,
                in: env
            )
            let extCommandArtifacts = discoverCommands(
                in: GeminiPathCatalog.extensionCommandsDirectory(in: extDir),
                scope: .user,
                enabled: isEnabled,
                in: env
            )

            var extHookArtifacts: [Artifact] = []
            let extHooksURL = GeminiPathCatalog.extensionHooksFile(in: extDir)
            if AdapterPathNormalizer.isEffectiveFile(extHooksURL, fileSystem: fs) {
                extHookArtifacts = GeminiPayloadParser.parseStandaloneHooksFile(
                    at: extHooksURL,
                    scope: .user,
                    enabled: isEnabled,
                    in: env
                )
            }

            let manifest = PluginManifest(
                name: extName,
                version: extVersion,
                description: extDescription,
                skills: extSkillArtifacts.map(\.name),
                agents: extSubagentArtifacts.map(\.name),
                commands: extCommandArtifacts.map(\.name),
                mcpServers: extMCPArtifacts.map(\.name)
            )

            results.append(
                Artifact(
                    id: pluginID,
                    agent: .gemini,
                    kind: .plugin,
                    scope: .user,
                    name: extName,
                    location: manifestLocation,
                    contentHash: contentHash,
                    enabled: isEnabled,
                    loadMode: .never,
                    payload: .plugin(manifest),
                    diagnostics: diagnostics
                )
            )
            results.append(contentsOf: extMCPArtifacts)
            results.append(contentsOf: extContextArtifacts)
            results.append(contentsOf: extSkillArtifacts)
            results.append(contentsOf: extSubagentArtifacts)
            results.append(contentsOf: extCommandArtifacts)
            results.append(contentsOf: extHookArtifacts)
        }

        return results
    }

    private static func isExtensionEnabled(
        name: String,
        directoryName: String,
        enablementTree: [String: JSONValue]?,
        disabledExtensions: Set<String>,
        targetFolder: URL?
    ) -> Bool {
        if disabledExtensions.contains(name) || disabledExtensions.contains(directoryName) {
            return false
        }

        guard let enablementTree else {
            return true
        }

        let rawEntry = enablementTree[name] ?? enablementTree[directoryName]
        guard case .object(let entryObj) = rawEntry else {
            return true
        }

        if let explicitFlag = GeminiPayloadParser.boolValue(entryObj["enabled"]) {
            if !explicitFlag { return false }
        }

        guard let overrides = GeminiPayloadParser.stringArray(entryObj["overrides"]), !overrides.isEmpty else {
            return true
        }

        let targetPath = targetFolder?.standardizedFileURL.path ?? ""
        var enabled = true
        for rule in overrides {
            let isNegated = rule.hasPrefix("!")
            let pattern = isNegated ? String(rule.dropFirst()) : rule
            if matchesEnablementOverridePattern(pattern, targetPath: targetPath) {
                enabled = !isNegated
            }
        }
        return enabled
    }

    private static func matchesEnablementOverridePattern(_ pattern: String, targetPath: String) -> Bool {
        if pattern == "*" || pattern == "/*" {
            return true
        }
        guard !targetPath.isEmpty else {
            return false
        }
        if pattern.hasSuffix("/*") {
            let prefix = String(pattern.dropLast(2))
            return targetPath == prefix || targetPath.hasPrefix(prefix + "/")
        }
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return targetPath.hasPrefix(prefix)
        }
        return targetPath == pattern
    }
}
