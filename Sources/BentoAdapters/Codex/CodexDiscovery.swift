import BentoCore
import BentoParsing
import Foundation

/// Read-only filesystem discovery engine for OpenAI Codex CLI across managed, user, built-in, project, and nested directory scopes.
enum CodexDiscovery {
    struct FolderHierarchy {
        let ancestorsAboveRepo: [URL]
        let repoRoot: URL
        let ancestorsInsideRepoToTarget: [URL]
        let targetFolder: URL
    }

    struct EffectiveConfigSummary {
        var isProjectTrusted: Bool = true
        var maxBytes: Int = CodexPathCatalog.defaultProjectDocMaxBytes
        var fallbackFilenames: [String] = []
        var allowManagedHooksOnly: Bool = false
        var disabledSkillIdentityPaths: Set<String> = []
    }

    /// Discovers all Codex CLI artifacts at global scope and, when `folder` is provided, workspace scope.
    static func discover(in env: AgentEnvironment, folder: URL?) -> [Artifact] {
        let fs = env.fileSystem
        let hierarchy = resolveFolderHierarchy(for: folder, in: env)
        let profileOverride = env.env[CodexPathCatalog.codexProfileEnvKey]

        // 1. Pre-parse TOML config tiers so trust_level, project_doc_max_bytes, and fallback filenames are known.
        let managedReqURL = CodexPathCatalog.managedRequirementsFile(in: env)
        let managedCfgURL = CodexPathCatalog.managedConfigFile(in: env)
        let userCfgURL = CodexPathCatalog.userConfigFile(in: env)

        let managedReqParsed =
            AdapterPathNormalizer.isEffectiveFile(managedReqURL, fileSystem: fs)
            ? CodexPayloadParser.parseTOMLConfig(
                at: managedReqURL,
                scope: .managed,
                activeProfileOverride: profileOverride,
                extractMCPAndHooks: false,
                in: env
            )
            : nil
        let managedCfgParsed =
            AdapterPathNormalizer.isEffectiveFile(managedCfgURL, fileSystem: fs)
            ? CodexPayloadParser.parseTOMLConfig(
                at: managedCfgURL,
                scope: .managed,
                activeProfileOverride: profileOverride,
                in: env
            )
            : nil
        let userCfgParsed =
            AdapterPathNormalizer.isEffectiveFile(userCfgURL, fileSystem: fs)
            ? CodexPayloadParser.parseTOMLConfig(
                at: userCfgURL,
                scope: .user,
                activeProfileOverride: profileOverride,
                in: env
            )
            : nil

        let isProjectTrusted = evaluateProjectTrust(
            userTree: userCfgParsed?.parsedTree,
            hierarchy: hierarchy,
            in: env
        )

        var projectCfgParsed: CodexPayloadParser.ParsedTOMLConfig?
        var directoryCfgParsedList: [(dir: URL, parsed: CodexPayloadParser.ParsedTOMLConfig)] = []

        if let hierarchy {
            let projCfgURL = CodexPathCatalog.directoryConfigFile(in: hierarchy.repoRoot)
            if AdapterPathNormalizer.isEffectiveFile(projCfgURL, fileSystem: fs) {
                projectCfgParsed = CodexPayloadParser.parseTOMLConfig(
                    at: projCfgURL,
                    scope: .project,
                    enabled: isProjectTrusted,
                    activeProfileOverride: profileOverride,
                    in: env
                )
            }
            for subdir in hierarchy.ancestorsInsideRepoToTarget {
                let dirCfgURL = CodexPathCatalog.directoryConfigFile(in: subdir)
                if AdapterPathNormalizer.isEffectiveFile(dirCfgURL, fileSystem: fs) {
                    let parsed = CodexPayloadParser.parseTOMLConfig(
                        at: dirCfgURL,
                        scope: .directory,
                        enabled: isProjectTrusted,
                        activeProfileOverride: profileOverride,
                        in: env
                    )
                    directoryCfgParsedList.append((subdir, parsed))
                }
            }
        }

        // Highest -> lowest precedence trees (excluding untrusted project/directory configs)
        var precedenceTrees: [[String: JSONValue]] = []
        if let tree = managedReqParsed?.parsedTree { precedenceTrees.append(tree) }
        if let tree = managedCfgParsed?.parsedTree { precedenceTrees.append(tree) }
        if isProjectTrusted {
            for item in directoryCfgParsedList.reversed() {
                if let tree = item.parsed.parsedTree { precedenceTrees.append(tree) }
            }
            if let tree = projectCfgParsed?.parsedTree { precedenceTrees.append(tree) }
        }
        if let tree = userCfgParsed?.parsedTree { precedenceTrees.append(tree) }

        let summary = buildEffectiveConfigSummary(
            precedenceTrees: precedenceTrees,
            isProjectTrusted: isProjectTrusted,
            in: env
        )

        var artifacts: [Artifact] = []

        // 2. Managed scope
        if let managedReqParsed {
            artifacts.append(managedReqParsed.settingsArtifact)
        }
        if let managedCfgParsed {
            artifacts.append(managedCfgParsed.settingsArtifact)
            artifacts.append(contentsOf: managedCfgParsed.mcpArtifacts)
            artifacts.append(contentsOf: managedCfgParsed.hookArtifacts)
        }
        let managedHooksURL = CodexPathCatalog.managedHooksFile(in: env)
        if AdapterPathNormalizer.isEffectiveFile(managedHooksURL, fileSystem: fs) {
            artifacts.append(
                contentsOf: CodexPayloadParser.parseStandaloneHooksFile(
                    at: managedHooksURL,
                    scope: .managed,
                    in: env
                )
            )
        }

        // 3. User & Built-in scope
        if let userCfgParsed {
            artifacts.append(userCfgParsed.settingsArtifact)
            artifacts.append(contentsOf: userCfgParsed.mcpArtifacts)
            artifacts.append(contentsOf: userCfgParsed.hookArtifacts)
        }
        let userHooksURL = CodexPathCatalog.userHooksFile(in: env)
        if AdapterPathNormalizer.isEffectiveFile(userHooksURL, fileSystem: fs) {
            artifacts.append(
                contentsOf: CodexPayloadParser.parseStandaloneHooksFile(
                    at: userHooksURL,
                    scope: .user,
                    enabled: !summary.allowManagedHooksOnly,
                    in: env
                )
            )
        }

        // Track cumulative active instruction bytes across global + repoRoot -> targetFolder
        var remainingBytes = max(0, summary.maxBytes)

        artifacts.append(
            contentsOf: discoverDirectoryRuleCandidates(
                in: CodexPathCatalog.userCodexDirectory(in: env),
                candidateFilenames: [CodexPathCatalog.rulesOverrideFilename, CodexPathCatalog.rulesFilename],
                scope: .user,
                namePrefix: nil,
                loadMode: .always,
                countsTowardActiveChain: true,
                remainingBytes: &remainingBytes,
                maxBytes: summary.maxBytes,
                env: env
            )
        )

        artifacts.append(
            contentsOf: discoverSkills(
                in: CodexPathCatalog.userAgentsSkillsDirectory(in: env),
                scope: .user,
                skippingSystemSubdir: false,
                disabledIdentityPaths: summary.disabledSkillIdentityPaths,
                in: env
            )
        )
        artifacts.append(
            contentsOf: discoverSkills(
                in: CodexPathCatalog.userCodexSkillsDirectory(in: env),
                scope: .user,
                skippingSystemSubdir: true,
                disabledIdentityPaths: summary.disabledSkillIdentityPaths,
                in: env
            )
        )
        artifacts.append(
            contentsOf: discoverSkills(
                in: CodexPathCatalog.builtInSystemSkillsDirectory(in: env),
                scope: .builtIn,
                skippingSystemSubdir: false,
                disabledIdentityPaths: summary.disabledSkillIdentityPaths,
                in: env
            )
        )

        // 4. Project & Directory scope
        if let hierarchy {
            let repoRoot = hierarchy.repoRoot
            let candidateRuleNames = CodexPathCatalog.orderedRuleCandidateFilenames(
                fallbackFilenames: summary.fallbackFilenames
            )

            if let projectCfgParsed {
                artifacts.append(projectCfgParsed.settingsArtifact)
                artifacts.append(contentsOf: projectCfgParsed.mcpArtifacts)
                artifacts.append(contentsOf: projectCfgParsed.hookArtifacts)
            }
            let projectHooksURL = CodexPathCatalog.directoryHooksFile(in: repoRoot)
            if AdapterPathNormalizer.isEffectiveFile(projectHooksURL, fileSystem: fs) {
                artifacts.append(
                    contentsOf: CodexPayloadParser.parseStandaloneHooksFile(
                        at: projectHooksURL,
                        scope: .project,
                        enabled: summary.isProjectTrusted && !summary.allowManagedHooksOnly,
                        in: env
                    )
                )
            }

            artifacts.append(
                contentsOf: discoverDirectoryRuleCandidates(
                    in: repoRoot,
                    candidateFilenames: candidateRuleNames,
                    scope: .project,
                    namePrefix: nil,
                    loadMode: .always,
                    countsTowardActiveChain: true,
                    remainingBytes: &remainingBytes,
                    maxBytes: summary.maxBytes,
                    env: env
                )
            )

            artifacts.append(
                contentsOf: discoverSkills(
                    in: CodexPathCatalog.directoryAgentsSkillsDirectory(in: repoRoot),
                    scope: .project,
                    skippingSystemSubdir: false,
                    disabledIdentityPaths: summary.disabledSkillIdentityPaths,
                    in: env
                )
            )
            artifacts.append(
                contentsOf: discoverSkills(
                    in: CodexPathCatalog.directoryCodexSkillsDirectory(in: repoRoot),
                    scope: .project,
                    skippingSystemSubdir: false,
                    disabledIdentityPaths: summary.disabledSkillIdentityPaths,
                    in: env
                )
            )

            let parsedDirCfgByPath = Dictionary(
                uniqueKeysWithValues: directoryCfgParsedList.map { ($0.dir.standardizedFileURL.path, $0.parsed) }
            )

            for subdir in hierarchy.ancestorsInsideRepoToTarget {
                if let dirParsed = parsedDirCfgByPath[subdir.standardizedFileURL.path] {
                    artifacts.append(dirParsed.settingsArtifact)
                    artifacts.append(contentsOf: dirParsed.mcpArtifacts)
                    artifacts.append(contentsOf: dirParsed.hookArtifacts)
                }

                let relDir = AdapterPathNormalizer.relativePath(
                    of: subdir,
                    from: repoRoot,
                    fileSystem: fs
                )
                artifacts.append(
                    contentsOf: discoverDirectoryRuleCandidates(
                        in: subdir,
                        candidateFilenames: candidateRuleNames,
                        scope: .directory,
                        namePrefix: relDir,
                        loadMode: .always,
                        countsTowardActiveChain: true,
                        remainingBytes: &remainingBytes,
                        maxBytes: summary.maxBytes,
                        env: env
                    )
                )

                artifacts.append(
                    contentsOf: discoverSkills(
                        in: CodexPathCatalog.directoryAgentsSkillsDirectory(in: subdir),
                        scope: .directory,
                        skippingSystemSubdir: false,
                        disabledIdentityPaths: summary.disabledSkillIdentityPaths,
                        in: env
                    )
                )
                artifacts.append(
                    contentsOf: discoverSkills(
                        in: CodexPathCatalog.directoryCodexSkillsDirectory(in: subdir),
                        scope: .directory,
                        skippingSystemSubdir: false,
                        disabledIdentityPaths: summary.disabledSkillIdentityPaths,
                        in: env
                    )
                )
            }

            artifacts.append(
                contentsOf: discoverDescendantRules(
                    hierarchy: hierarchy,
                    candidateFilenames: candidateRuleNames,
                    maxBytes: summary.maxBytes,
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
                if CodexPathCatalog.hasGitMarker(in: cursor, fileSystem: fs) {
                    break
                }
                let parent = cursor.deletingLastPathComponent().standardizedFileURL
                if parent.path == cursor.path || parent.path == "/" {
                    break
                }
                cursor = parent
            }
            if let gitRootIndex = upward.firstIndex(where: { CodexPathCatalog.hasGitMarker(in: $0, fileSystem: fs) }) {
                chain = Array(upward[0...gitRootIndex].reversed())
            } else {
                chain = [targetFolder]
            }
        }

        guard !chain.isEmpty else { return nil }

        let repoIndex: Int
        if let nearestGitIdx = chain.lastIndex(where: { CodexPathCatalog.hasGitMarker(in: $0, fileSystem: fs) }) {
            repoIndex = nearestGitIdx
        } else if let outermostCodexIdx = chain.firstIndex(where: {
            CodexPathCatalog.hasCodexRootMarkers(in: $0, fileSystem: fs)
        }) {
            repoIndex = outermostCodexIdx
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

    // MARK: - Trust & Config Summary

    static func evaluateProjectTrust(
        userTree: [String: JSONValue]?,
        hierarchy: FolderHierarchy?,
        in env: AgentEnvironment
    ) -> Bool {
        guard let userTree,
            case .object(let projectsMap) = userTree["projects"],
            let hierarchy
        else {
            return true
        }

        let fs = env.fileSystem
        let candidates = ([hierarchy.repoRoot] + hierarchy.ancestorsInsideRepoToTarget + hierarchy.ancestorsAboveRepo)
        var candidatePaths: Set<String> = []
        for url in candidates {
            candidatePaths.insert(url.standardizedFileURL.path)
            candidatePaths.insert(fs.resolveSymlinks(url).standardizedFileURL.path)
        }

        for key in projectsMap.keys.sorted() {
            guard case .object(let projEntry) = projectsMap[key] else { continue }
            let expanded = AdapterPathNormalizer.expandHomePrefix(key, in: env)
            let stdPath = expanded.standardizedFileURL.path
            let realPath = fs.resolveSymlinks(expanded).standardizedFileURL.path
            if candidatePaths.contains(stdPath) || candidatePaths.contains(realPath) {
                if let level = CodexPayloadParser.stringValue(projEntry["trust_level"])?.lowercased(),
                    level == "untrusted"
                {
                    return false
                }
            }
        }
        return true
    }

    static func buildEffectiveConfigSummary(
        precedenceTrees: [[String: JSONValue]],
        isProjectTrusted: Bool,
        in env: AgentEnvironment
    ) -> EffectiveConfigSummary {
        var summary = EffectiveConfigSummary(isProjectTrusted: isProjectTrusted)

        for tree in precedenceTrees {
            if let maxBytes = CodexPayloadParser.intValue(tree["project_doc_max_bytes"]) {
                summary.maxBytes = max(0, maxBytes)
                break
            }
        }

        for tree in precedenceTrees {
            if let fallbacks = CodexPayloadParser.stringArray(tree["project_doc_fallback_filenames"]) {
                summary.fallbackFilenames = fallbacks
                break
            }
        }

        for tree in precedenceTrees {
            if let managedOnly = CodexPayloadParser.boolValue(tree["allow_managed_hooks_only"]) {
                summary.allowManagedHooksOnly = managedOnly
                break
            }
        }

        for tree in precedenceTrees.reversed() {
            if case .object(let skillsObj) = tree["skills"],
                case .array(let configList) = skillsObj["config"]
            {
                for item in configList {
                    guard case .object(let itemDict) = item,
                        let rawPath = CodexPayloadParser.nonEmptyString(itemDict["path"])
                    else {
                        continue
                    }
                    let expanded = AdapterPathNormalizer.expandHomePrefix(rawPath, in: env)
                    let manifestURL =
                        expanded.lastPathComponent == CodexPathCatalog.skillManifestFilename
                        ? expanded
                        : expanded.appendingPathComponent(CodexPathCatalog.skillManifestFilename)
                    let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: manifestURL, in: env)
                    if CodexPayloadParser.boolValue(itemDict["enabled"]) == false {
                        summary.disabledSkillIdentityPaths.insert(identityPath)
                    } else if CodexPayloadParser.boolValue(itemDict["enabled"]) == true {
                        summary.disabledSkillIdentityPaths.remove(identityPath)
                    }
                }
            }
        }

        return summary
    }

    // MARK: - Rule Candidates & Descendants

    private static func discoverDirectoryRuleCandidates(
        in directory: URL,
        candidateFilenames: [String],
        scope: Scope,
        namePrefix: String?,
        loadMode: LoadMode,
        countsTowardActiveChain: Bool,
        remainingBytes: inout Int,
        maxBytes: Int,
        env: AgentEnvironment
    ) -> [Artifact] {
        let fs = env.fileSystem
        var discovered: [Artifact] = []
        var winnerClaimedInDirectory = false

        for filename in candidateFilenames {
            let fileURL = directory.appendingPathComponent(filename).standardizedFileURL
            guard AdapterPathNormalizer.isEffectiveFile(fileURL, fileSystem: fs) else {
                continue
            }

            let rawBytes = (try? fs.contents(at: fileURL)) ?? Data()
            let isNonEmpty = !String(decoding: rawBytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            var wasTruncated = false
            if countsTowardActiveChain, !winnerClaimedInDirectory, isNonEmpty {
                winnerClaimedInDirectory = true
                if rawBytes.count > remainingBytes {
                    wasTruncated = true
                    remainingBytes = 0
                } else {
                    remainingBytes -= rawBytes.count
                }
            } else if !countsTowardActiveChain, rawBytes.count > maxBytes {
                wasTruncated = true
            }

            let displayName: String =
                if let namePrefix, !namePrefix.isEmpty {
                    "\(namePrefix)/\(filename)"
                } else {
                    filename
                }

            discovered.append(
                CodexPayloadParser.parseRulesFile(
                    at: fileURL,
                    scope: scope,
                    name: displayName,
                    loadMode: loadMode,
                    wasTruncated: wasTruncated,
                    maxBytes: maxBytes,
                    in: env
                )
            )
        }

        return discovered
    }

    private static func discoverDescendantRules(
        hierarchy: FolderHierarchy,
        candidateFilenames: [String],
        maxBytes: Int,
        in env: AgentEnvironment
    ) -> [Artifact] {
        let fs = env.fileSystem
        let candidateSet = Set(candidateFilenames)
        let targetStdPath = hierarchy.targetFolder.standardizedFileURL.path

        let files = AdapterPathNormalizer.collectFilesRecursively(
            under: hierarchy.targetFolder,
            skippingDirectoryNames: CodexPathCatalog.skippedDescendantDirectoryNames,
            fileSystem: fs
        ) { url in
            let parentPath = url.deletingLastPathComponent().standardizedFileURL.path
            return parentPath != targetStdPath && candidateSet.contains(url.lastPathComponent)
        }

        // Group by directory to preserve candidate priority order within each descendant directory
        var dirsInOrder: [URL] = []
        var seenDirs: Set<String> = []
        for fileURL in files {
            let dir = fileURL.deletingLastPathComponent().standardizedFileURL
            if seenDirs.insert(dir.path).inserted {
                dirsInOrder.append(dir)
            }
        }

        var results: [Artifact] = []
        for dir in dirsInOrder {
            let relFromTarget =
                AdapterPathNormalizer.relativePath(
                    of: dir,
                    from: hierarchy.targetFolder,
                    fileSystem: fs
                ) ?? dir.lastPathComponent
            let relFromRepo =
                AdapterPathNormalizer.relativePath(
                    of: dir,
                    from: hierarchy.repoRoot,
                    fileSystem: fs
                ) ?? relFromTarget
            var unusedBudget = maxBytes
            results.append(
                contentsOf: discoverDirectoryRuleCandidates(
                    in: dir,
                    candidateFilenames: candidateFilenames,
                    scope: .directory,
                    namePrefix: relFromRepo,
                    loadMode: .conditional(globs: ["\(relFromTarget)/**"]),
                    countsTowardActiveChain: false,
                    remainingBytes: &unusedBudget,
                    maxBytes: maxBytes,
                    env: env
                )
            )
        }

        return results
    }

    // MARK: - Skills

    private static func discoverSkills(
        in skillsRoot: URL,
        scope: Scope,
        skippingSystemSubdir: Bool,
        disabledIdentityPaths: Set<String>,
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
            let dirName = entry.lastPathComponent
            if skippingSystemSubdir && CodexPathCatalog.isSystemSkillsSubdirectoryName(dirName) {
                continue
            }
            guard AdapterPathNormalizer.isEffectiveDirectory(entry, fileSystem: fs) else {
                continue
            }
            let manifestURL = entry.appendingPathComponent(CodexPathCatalog.skillManifestFilename)
            guard AdapterPathNormalizer.isEffectiveFile(manifestURL, fileSystem: fs) else {
                continue
            }
            let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: manifestURL, in: env)
            let isEnabled = !disabledIdentityPaths.contains(identityPath)
            results.append(
                CodexPayloadParser.parseSkill(
                    skillDirectory: entry,
                    manifestURL: manifestURL,
                    scope: scope,
                    enabled: isEnabled,
                    in: env
                )
            )
        }

        return results
    }
}
