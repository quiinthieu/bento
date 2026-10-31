import BentoAdapters
import BentoCore
import Foundation

/// Maps changed filesystem paths to affected `ScanScope` units via `PathCatalog` glob matching (`PLAN.md` §6.1).
public struct PathCatalogMatcher: Sendable {
    /// Evaluates `changedPaths` against `adapters`' `PathCatalog` entries in `env` across `repos`.
    public static func match(
        changedPaths: [String],
        adapters: [any AgentAdapter],
        repos: [DiscoveredRepo],
        in env: AgentEnvironment
    ) -> PathCatalogMatch {
        guard !changedPaths.isEmpty else {
            return PathCatalogMatch()
        }

        let normalizedTargets = changedPaths.flatMap { candidateVariants(for: $0, in: env) }
        guard !normalizedTargets.isEmpty else {
            return PathCatalogMatch()
        }

        var matchedScopes: Set<ScanScope> = []
        var matchedLogAgents: Set<AgentID> = []

        for adapter in adapters {
            let agentID = type(of: adapter).id
            for entry in adapter.paths.entries {
                if isLogEntry(entry) {
                    let logGlobs = expandGlobalGlobs(for: entry, agent: agentID, isLog: true, in: env)
                    if matchesAny(paths: normalizedTargets, globs: logGlobs) {
                        matchedLogAgents.insert(agentID)
                    }
                    continue
                }

                if entry.pattern.hasPrefix("<repo>/") {
                    let suffix = String(entry.pattern.dropFirst("<repo>/".count))
                    for repo in repos {
                        let repoGlobs = expandRepoGlobs(
                            suffix: suffix,
                            entryKind: entry.kind,
                            repo: repo
                        )
                        if matchesAny(paths: normalizedTargets, globs: repoGlobs) {
                            matchedScopes.insert(ScanScope(agent: agentID, repoPath: repo.path))
                        }
                    }
                } else if entry.pattern.hasPrefix("<subdir>/") {
                    let suffix = String(entry.pattern.dropFirst("<subdir>/".count))
                    for repo in repos {
                        let subdirGlobs = expandSubdirGlobs(
                            suffix: suffix,
                            repo: repo,
                            in: env
                        )
                        if matchesAny(paths: normalizedTargets, globs: subdirGlobs) {
                            matchedScopes.insert(ScanScope(agent: agentID, repoPath: repo.path))
                        }
                    }
                } else {
                    let globalGlobs = expandGlobalGlobs(
                        for: entry,
                        agent: agentID,
                        isLog: false,
                        in: env
                    )
                    if matchesAny(paths: normalizedTargets, globs: globalGlobs) {
                        matchedScopes.insert(ScanScope(agent: agentID, repoPath: nil))
                        for repo in repos {
                            matchedScopes.insert(ScanScope(agent: agentID, repoPath: repo.path))
                        }
                    }
                }
            }
        }

        return PathCatalogMatch(scopes: matchedScopes, logAgents: matchedLogAgents)
    }

    // MARK: - Pattern Classification & Expansion

    private static func isLogEntry(_ entry: PathCatalog.Entry) -> Bool {
        entry.id.hasSuffix(".logs") || entry.id.hasSuffix(".sessionLogs")
    }

    private static func candidateVariants(for rawPath: String, in env: AgentEnvironment) -> [[String]] {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let stdURL = URL(fileURLWithPath: trimmed).standardizedFileURL
        var variants: Set<String> = [stdURL.path]

        if env.fileSystem.exists(stdURL) {
            let real = env.fileSystem.resolveSymlinks(stdURL).standardizedFileURL.path
            variants.insert(real)
        } else {
            let parent = stdURL.deletingLastPathComponent()
            if env.fileSystem.exists(parent) {
                let realParent = env.fileSystem.resolveSymlinks(parent).standardizedFileURL
                let reconstructed =
                    realParent
                    .appendingPathComponent(stdURL.lastPathComponent)
                    .standardizedFileURL
                    .path
                variants.insert(reconstructed)
            }
        }

        return variants.sorted().map { splitSegments($0) }
    }

    private static func expandGlobalGlobs(
        for entry: PathCatalog.Entry,
        agent: AgentID,
        isLog: Bool,
        in env: AgentEnvironment
    ) -> [[String]] {
        var rawGlobs: Set<String> = []
        let pattern = entry.pattern

        if pattern.hasPrefix("/") {
            let relSuffix = String(pattern.dropFirst())
            for sysRoot in directoryVariants(AdapterPathNormalizer.systemRootURL(in: env), in: env) {
                let joined = joinPath(base: sysRoot, suffix: relSuffix)
                rawGlobs.insert(joined)
            }
            if entry.id == "gemini.managed.settings" {
                let custom = GeminiPathCatalog.managedSettingsFile(in: env).standardizedFileURL.path
                rawGlobs.insert(custom)
            } else if entry.id == "gemini.systemDefaults.settings" {
                let custom = GeminiPathCatalog.systemDefaultsFile(in: env).standardizedFileURL.path
                rawGlobs.insert(custom)
            }
        } else if pattern.hasPrefix("~/") {
            let relSuffix = String(pattern.dropFirst(2))
            let unoverriddenEnv = AgentEnvironment(
                home: env.home,
                env: [:],
                fileSystem: env.fileSystem,
                now: env.now
            )
            let defaultAgentDir = userAgentDirectory(for: agent, in: unoverriddenEnv)?.standardizedFileURL.path
            let activeAgentDir = userAgentDirectory(for: agent, in: env)

            for homeBase in directoryVariants(env.home, in: env) {
                rawGlobs.insert(joinPath(base: homeBase, suffix: relSuffix))
            }

            if let defaultAgentDir, let activeAgentDir {
                let defaultExpanded = joinPath(base: env.home.standardizedFileURL.path, suffix: relSuffix)
                if defaultExpanded == defaultAgentDir || defaultExpanded.hasPrefix(defaultAgentDir + "/") {
                    let tail = String(defaultExpanded.dropFirst(defaultAgentDir.count))
                    for activeVariant in directoryVariants(activeAgentDir, in: env) {
                        rawGlobs.insert(activeVariant + tail)
                    }
                }
            }
        }

        var expandedWithCompanions = rawGlobs
        for glob in rawGlobs {
            if isLog {
                expandedWithCompanions.insert(glob + ".zst")
                if glob.hasSuffix(".json") {
                    expandedWithCompanions.insert(glob + "l")
                    expandedWithCompanions.insert(glob + "l.zst")
                }
                let parentDir = (glob as NSString).deletingLastPathComponent
                if !parentDir.isEmpty && parentDir != "/" {
                    expandedWithCompanions.insert(parentDir + "/**")
                }
            } else if entry.kind == .skill {
                let skillDir = (glob as NSString).deletingLastPathComponent
                if !skillDir.isEmpty && skillDir != "/" {
                    expandedWithCompanions.insert(skillDir + "/**")
                }
            } else if entry.kind == .plugin {
                if agent == .claudeCode {
                    for cacheRoot in directoryVariants(
                        ClaudeCodePathCatalog.userPluginsCacheDirectory(in: env),
                        in: env
                    ) {
                        expandedWithCompanions.insert(cacheRoot + "/**")
                    }
                } else if agent == .gemini {
                    for extRoot in directoryVariants(
                        GeminiPathCatalog.userExtensionsDirectory(in: env),
                        in: env
                    ) {
                        expandedWithCompanions.insert(extRoot + "/**")
                    }
                }
            }
        }

        return expandedWithCompanions.sorted().map { splitSegments($0) }
    }

    private static func expandRepoGlobs(
        suffix: String,
        entryKind: ArtifactKind,
        repo: DiscoveredRepo
    ) -> [[String]] {
        var rawGlobs: Set<String> = []
        for base in Set([repo.path, repo.realPath]) where !base.isEmpty {
            let joined = joinPath(base: base, suffix: suffix)
            rawGlobs.insert(joined)
            if entryKind == .skill {
                let skillDir = (joined as NSString).deletingLastPathComponent
                if !skillDir.isEmpty && skillDir != "/" {
                    rawGlobs.insert(skillDir + "/**")
                }
            }
        }
        return rawGlobs.sorted().map { splitSegments($0) }
    }

    private static func expandSubdirGlobs(
        suffix: String,
        repo: DiscoveredRepo,
        in env: AgentEnvironment
    ) -> [[String]] {
        var rawGlobs: Set<String> = []
        let homeVariants = Set(directoryVariants(env.home, in: env))

        for base in Set([repo.path, repo.realPath]) where !base.isEmpty {
            rawGlobs.insert(joinPath(base: base, suffix: "**/" + suffix))

            // Include intermediate ancestor directories strictly between env.home and repo.
            var cursor = URL(fileURLWithPath: base).standardizedFileURL.deletingLastPathComponent()
            while cursor.path != "/" && !cursor.path.isEmpty {
                if homeVariants.contains(cursor.path) {
                    break
                }
                let isUnderHome = homeVariants.contains { cursor.path.hasPrefix($0 + "/") }
                if !isUnderHome {
                    break
                }
                rawGlobs.insert(joinPath(base: cursor.path, suffix: suffix))
                let next = cursor.deletingLastPathComponent()
                if next.path == cursor.path { break }
                cursor = next
            }
        }

        return rawGlobs.sorted().map { splitSegments($0) }
    }

    private static func userAgentDirectory(for agent: AgentID, in env: AgentEnvironment) -> URL? {
        switch agent {
        case .claudeCode:
            return ClaudeCodePathCatalog.userConfigDirectory(in: env)
        case .codex:
            return CodexPathCatalog.userCodexDirectory(in: env)
        case .gemini:
            return GeminiPathCatalog.userGeminiDirectory(in: env)
        case .copilot:
            return CopilotPathCatalog.userCopilotDirectory(in: env)
        case .cursor:
            return CursorPathCatalog.userCursorDirectory(in: env)
        case .windsurf:
            return WindsurfPathCatalog.userWindsurfDirectory(in: env)
        }
    }

    private static func directoryVariants(_ url: URL, in env: AgentEnvironment) -> [String] {
        let std = url.standardizedFileURL
        var set: Set<String> = [std.path]
        if env.fileSystem.exists(std) {
            set.insert(env.fileSystem.resolveSymlinks(std).standardizedFileURL.path)
        }
        return set.sorted()
    }

    private static func joinPath(base: String, suffix: String) -> String {
        if base == "/" {
            return "/" + suffix
        }
        return base.hasSuffix("/") ? (base + suffix) : (base + "/" + suffix)
    }

    private static func splitSegments(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - Segment & Wildcard Glob Matcher

    private static func matchesAny(paths: [[String]], globs: [[String]]) -> Bool {
        for pathSegments in paths {
            for globSegments in globs where matchSegments(path: pathSegments, pattern: globSegments) {
                return true
            }
        }
        return false
    }

    private static func matchSegments(path: [String], pattern: [String]) -> Bool {
        let pCount = path.count
        let gCount = pattern.count
        var dp = Array(
            repeating: Array(repeating: false, count: gCount + 1),
            count: pCount + 1
        )
        dp[0][0] = true

        for j in 1...gCount where pattern[j - 1] == "**" {
            if dp[0][j - 1] {
                dp[0][j] = true
            }
        }

        if pCount == 0 {
            return dp[0][gCount]
        }

        for i in 1...pCount {
            for j in 1...gCount {
                let token = pattern[j - 1]
                if token == "**" {
                    // '**' matches zero segments (dp[i][j - 1]) or one more segment (dp[i - 1][j]).
                    dp[i][j] = dp[i][j - 1] || dp[i - 1][j]
                } else if dp[i - 1][j - 1] && matchSingleSegment(text: path[i - 1], glob: token) {
                    dp[i][j] = true
                }
            }
        }

        return dp[pCount][gCount]
    }

    private static func matchSingleSegment(text: String, glob: String) -> Bool {
        if glob == "*" {
            return true
        }
        if !glob.contains("*") && !glob.contains("?") {
            return text == glob
        }

        let tBytes = Array(text.utf8)
        let gBytes = Array(glob.utf8)
        var tIdx = 0
        var gIdx = 0
        var starIdx: Int?
        var matchIdx = 0

        let star = UInt8(ascii: "*")
        let qmark = UInt8(ascii: "?")

        while tIdx < tBytes.count {
            if gIdx < gBytes.count && (gBytes[gIdx] == qmark || gBytes[gIdx] == tBytes[tIdx]) {
                tIdx += 1
                gIdx += 1
            } else if gIdx < gBytes.count && gBytes[gIdx] == star {
                starIdx = gIdx
                matchIdx = tIdx
                gIdx += 1
            } else if let savedStar = starIdx {
                gIdx = savedStar + 1
                matchIdx += 1
                tIdx = matchIdx
            } else {
                return false
            }
        }

        while gIdx < gBytes.count && gBytes[gIdx] == star {
            gIdx += 1
        }
        return gIdx == gBytes.count
    }
}
