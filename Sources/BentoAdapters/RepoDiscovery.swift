import BentoCore
import BentoParsing
import CryptoKit
import Foundation

/// Read-only multi-agent repository discovery engine (`PLAN.md` §5.3).
/// Extracts workspace paths from Claude Code, Codex CLI, Gemini CLI, Copilot CLI, manual folders,
/// and optional shallow `.git` scans, deduplicating by canonical `realPath` and ignoring missing directories.
public enum RepoDiscovery: Sendable {
    private static let maxLogInspectBytes = 65_536
    private static let maxLogInspectLines = 32

    private static let skippedShallowDirectories: Set<String> = [
        ".git",
        "Library",
        "node_modules",
        ".build",
        "DerivedData",
        "Pods",
        "Carthage",
        "target",
        "dist",
        "build",
        "vendor",
        ".venv",
        "venv"
    ]

    private struct Accumulator {
        var preferredPath: String
        var preferredIsDirect: Bool
        var realPath: String
        var sources: Set<RepoDiscoverySource>
    }

    /// Discovers all existing repositories referenced across agent configs/logs, manual paths, and shallow scans.
    public static func discover(
        in env: AgentEnvironment,
        options: RepoDiscoveryOptions = RepoDiscoveryOptions()
    ) -> [DiscoveredRepo] {
        let fs = env.fileSystem
        let stdHome = env.home.standardizedFileURL
        let realHome = fs.resolveSymlinks(stdHome).standardizedFileURL.path

        let normalizedHidden = normalizePathSet(options.hiddenPaths, in: env)
        let normalizedPinned = normalizePathSet(options.pinnedPaths, in: env)

        var accumulators: [String: Accumulator] = [:]

        func record(_ rawURL: URL, source: RepoDiscoverySource) {
            let stdURL = rawURL.standardizedFileURL
            guard AdapterPathNormalizer.isEffectiveDirectory(stdURL, fileSystem: fs) else {
                return
            }

            let rootURL = normalizeToGitRootIfPresent(stdURL, stdHome: stdHome, realHome: realHome, fileSystem: fs)
            let candidatePath = rootURL.standardizedFileURL.path
            let realURL = fs.resolveSymlinks(rootURL).standardizedFileURL
            let realPath = realURL.path

            guard realPath != realHome && realPath != "/" else {
                return
            }

            let isSymlink = (try? fs.attributes(rootURL).isSymlink) == true
            let isDirect = !isSymlink && (candidatePath == realPath)

            if var existing = accumulators[realPath] {
                existing.sources.insert(source)
                if isDirect && !existing.preferredIsDirect {
                    existing.preferredPath = candidatePath
                    existing.preferredIsDirect = true
                } else if isDirect == existing.preferredIsDirect && candidatePath < existing.preferredPath {
                    existing.preferredPath = candidatePath
                }
                accumulators[realPath] = existing
            } else {
                accumulators[realPath] = Accumulator(
                    preferredPath: candidatePath,
                    preferredIsDirect: isDirect,
                    realPath: realPath,
                    sources: [source]
                )
            }
        }

        // (1) Claude Code: `~/.claude.json` project keys + `~/.claude/projects/<encoded-cwd>` & JSONL `cwd`
        discoverClaudeRepos(in: env, record: record)

        // (2) Codex CLI: `~/.codex/config.toml` `[projects.*]` + rollout logs `session_meta.cwd`
        discoverCodexRepos(in: env, record: record)

        // (4) Copilot CLI: `~/.copilot/config.json` `trusted_folders` + `session-state/*/{workspace.yaml,events.jsonl}`
        discoverCopilotRepos(in: env, record: record)

        // (5) Manual user folders
        for manualURL in options.manualPaths {
            record(manualURL, source: .manual)
        }

        // (6) Optional shallow scan of `~/Developer`, `~/code`, `~/src`, `~/Projects` (depth <= 3, `.git` present)
        if options.includeShallowScan && options.shallowScanMaxDepth >= 1 {
            for relativeRoot in options.shallowScanRelativeRoots {
                let rootURL = stdHome.appendingPathComponent(relativeRoot, isDirectory: true).standardizedFileURL
                shallowScanGitRepos(
                    under: rootURL,
                    maxDepth: options.shallowScanMaxDepth,
                    fileSystem: fs,
                    record: record
                )
            }
        }

        // (3) Gemini CLI: match `<project-hash>` directories under `~/.gemini/tmp/` against known & candidate cwds
        discoverGeminiRepos(
            in: env,
            knownRealPaths: Array(accumulators.keys),
            extraCandidates: options.knownCandidatePaths,
            record: record
        )

        // Retain pinned folders even when no active log/shallow-scan source currently mentions them,
        // without adding a spurious `.manual` source to already-discovered repos.
        for pinnedRaw in options.pinnedPaths {
            let expanded = AdapterPathNormalizer.expandHomePrefix(pinnedRaw, in: env).standardizedFileURL
            guard AdapterPathNormalizer.isEffectiveDirectory(expanded, fileSystem: fs) else { continue }
            let rootURL = normalizeToGitRootIfPresent(expanded, stdHome: stdHome, realHome: realHome, fileSystem: fs)
            let realPath = fs.resolveSymlinks(rootURL).standardizedFileURL.path
            if accumulators[realPath] == nil {
                record(expanded, source: .manual)
            }
        }

        // Filter hidden repos and build deterministic sorted result list
        var results: [DiscoveredRepo] = []
        for entry in accumulators.values {
            if normalizedHidden.contains(entry.realPath) || normalizedHidden.contains(entry.preferredPath) {
                continue
            }
            let isPinned = normalizedPinned.contains(entry.realPath) || normalizedPinned.contains(entry.preferredPath)
            let displayName = URL(fileURLWithPath: entry.preferredPath).lastPathComponent
            results.append(
                DiscoveredRepo(
                    path: entry.preferredPath,
                    realPath: entry.realPath,
                    displayName: displayName,
                    sources: Array(entry.sources).sorted(),
                    isPinned: isPinned
                )
            )
        }

        results.sort { lhs, rhs in
            if lhs.path != rhs.path {
                return lhs.path < rhs.path
            }
            return lhs.realPath < rhs.realPath
        }
        return results
    }

    // MARK: - (1) Claude Code

    private static func discoverClaudeRepos(
        in env: AgentEnvironment,
        record: (URL, RepoDiscoverySource) -> Void
    ) {
        let fs = env.fileSystem

        // 1a. `~/.claude.json` -> `projects` dictionary keys
        let stateFile = ClaudeCodePathCatalog.userStateFile(in: env)
        if AdapterPathNormalizer.isEffectiveFile(stateFile, fileSystem: fs),
            let rawData = try? fs.contents(at: stateFile)
        {
            let (settingsDoc, _) = JSONCParser.parseSettings(rawData, redactSecrets: false)
            if case .object(let projectsMap) = settingsDoc?.tree["projects"] {
                for rawKey in projectsMap.keys.sorted() {
                    let expanded = AdapterPathNormalizer.expandHomePrefix(rawKey, in: env)
                    record(expanded, .claudeState)
                }
            }
        }

        // 1b. `~/.claude/projects/<encoded-cwd>` directory names & JSONL `"cwd"` fields
        let projectsRoot = ClaudeCodePathCatalog.userLogsDirectory(in: env)
        guard AdapterPathNormalizer.isEffectiveDirectory(projectsRoot, fileSystem: fs),
            let projectDirs = try? fs.list(projectsRoot)
        else {
            return
        }

        let sortedDirs = projectDirs.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dirURL in sortedDirs where AdapterPathNormalizer.isEffectiveDirectory(dirURL, fileSystem: fs) {
            var matchedFromJSONL = false
            if let logEntries = try? fs.list(dirURL) {
                for logURL in logEntries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                where logURL.pathExtension.lowercased() == "jsonl"
                    && AdapterPathNormalizer.isEffectiveFile(logURL, fileSystem: fs)
                {
                    for cwd in extractCwdsFromJSONLPrefix(at: logURL, in: env) {
                        record(cwd, .claudeLogs)
                        matchedFromJSONL = true
                    }
                }
            }

            if let decodedURL = decodeClaudeEncodedProjectDirName(dirURL.lastPathComponent, in: env) {
                record(decodedURL, .claudeLogs)
            } else if !matchedFromJSONL {
                continue
            }
        }
    }

    /// Decodes Claude Code's hyphen-encoded project directory name (e.g. `-repos-webapp` or
    /// `-Users-alice-Developer-org-alpha-service`) by matching real directory segments through `env.fileSystem`.
    static func decodeClaudeEncodedProjectDirName(
        _ encodedName: String,
        in env: AgentEnvironment
    ) -> URL? {
        let trimmed = encodedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("-") else { return nil }

        let fs = env.fileSystem
        let stdHome = env.home.standardizedFileURL
        let realHome = fs.resolveSymlinks(stdHome)

        let body = String(trimmed.dropFirst())
        guard !body.isEmpty else { return nil }

        let bodyTokens = claudeTokenizeSegment(body)
        guard !bodyTokens.isEmpty else { return nil }

        // Check home-prefixed encodings first (`Users-alice-...` or real symlinked home prefix),
        // handling both `/` -> `-` and `[^A-Za-z0-9]` -> `-` encodings uniformly.
        for homeCandidate in [stdHome, realHome] {
            let homeTokens = claudeTokenizeSegment(homeCandidate.standardizedFileURL.path)
            if !homeTokens.isEmpty
                && bodyTokens.count > homeTokens.count
                && bodyTokens.starts(with: homeTokens)
            {
                let remainder = Array(bodyTokens.dropFirst(homeTokens.count))
                if let resolved = matchHyphenTokens(remainder, index: 0, under: stdHome, fileSystem: fs) {
                    return resolved
                }
            }
        }

        // Check fixture/home-relative encodings (`-repos-webapp`, `-repos-demo-app`)
        if let resolved = matchHyphenTokens(bodyTokens, index: 0, under: stdHome, fileSystem: fs) {
            return resolved
        }

        return nil
    }

    private static func claudeTokenizeSegment(_ segment: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for scalar in segment.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func matchHyphenTokens(
        _ tokens: [String],
        index: Int,
        under currentDir: URL,
        fileSystem: any ReadOnlyFileSystem
    ) -> URL? {
        if index == tokens.count {
            return AdapterPathNormalizer.isEffectiveDirectory(currentDir, fileSystem: fileSystem)
                ? currentDir.standardizedFileURL
                : nil
        }

        guard let children = try? fileSystem.list(currentDir) else {
            return nil
        }

        // Try longest segment token matches first so `demo-app` is preferred over `demo/app` when both exist.
        var candidates: [(url: URL, tokenCount: Int)] = []
        for child in children where AdapterPathNormalizer.isEffectiveDirectory(child, fileSystem: fileSystem) {
            let segTokens = claudeTokenizeSegment(child.lastPathComponent)
            guard !segTokens.isEmpty, index + segTokens.count <= tokens.count else { continue }
            if Array(tokens[index..<(index + segTokens.count)]) == segTokens {
                candidates.append((child.standardizedFileURL, segTokens.count))
            }
        }

        candidates.sort { lhs, rhs in
            if lhs.tokenCount != rhs.tokenCount {
                return lhs.tokenCount > rhs.tokenCount
            }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }

        for candidate in candidates {
            if let found = matchHyphenTokens(
                tokens,
                index: index + candidate.tokenCount,
                under: candidate.url,
                fileSystem: fileSystem
            ) {
                return found
            }
        }
        return nil
    }

    // MARK: - (2) Codex CLI

    private static func discoverCodexRepos(
        in env: AgentEnvironment,
        record: (URL, RepoDiscoverySource) -> Void
    ) {
        let fs = env.fileSystem

        // 2a. `~/.codex/config.toml` -> `[projects."<path>"]`
        let configFile = CodexPathCatalog.userConfigFile(in: env)
        if AdapterPathNormalizer.isEffectiveFile(configFile, fileSystem: fs),
            let rawData = try? fs.contents(at: configFile)
        {
            let (settingsDoc, _) = TOMLParser.parseSettings(rawData, redactSecrets: false)
            if case .object(let projectsMap) = settingsDoc?.tree["projects"] {
                for rawKey in projectsMap.keys.sorted() {
                    let expanded = AdapterPathNormalizer.expandHomePrefix(rawKey, in: env)
                    record(expanded, .codexConfig)
                }
            }
        }

        // 2b. `~/.codex/sessions/**/*.jsonl` -> `session_meta` `payload.cwd`
        let sessionsRoot = CodexPathCatalog.userLogsDirectory(in: env)
        let sessionFiles = AdapterPathNormalizer.collectFilesRecursively(under: sessionsRoot, fileSystem: fs) { url in
            url.pathExtension.lowercased() == "jsonl"
        }

        for fileURL in sessionFiles {
            for cwdURL in extractCwdsFromJSONLPrefix(at: fileURL, in: env) {
                record(cwdURL, .codexLogs)
            }
        }
    }

    // MARK: - (3) Gemini CLI

    /// Resolves Gemini `<project-hash>` directory names under `~/.gemini/tmp/` to standardized workspace paths.
    static func resolveGeminiProjectCwdsByHash(in env: AgentEnvironment) -> [String: String] {
        let fs = env.fileSystem
        let tmpRoot = GeminiPathCatalog.userLogsRootDirectory(in: env)
        guard AdapterPathNormalizer.isEffectiveDirectory(tmpRoot, fileSystem: fs),
            let entries = try? fs.list(tmpRoot)
        else {
            return [:]
        }

        var resolvedByFolderName: [String: String] = [:]
        var targetHashes: Set<String> = []
        for entry in entries where AdapterPathNormalizer.isEffectiveDirectory(entry, fileSystem: fs) {
            let folderName = entry.lastPathComponent.lowercased()
            let projectRootMarker = entry.appendingPathComponent(".project_root")
            if AdapterPathNormalizer.isEffectiveFile(projectRootMarker, fileSystem: fs),
                let data = try? fs.contents(at: projectRootMarker),
                let rawPath = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !rawPath.isEmpty
            {
                let expanded = AdapterPathNormalizer.expandHomePrefix(rawPath, in: env).standardizedFileURL
                resolvedByFolderName[folderName] = expanded.path
                continue
            }

            if folderName.count == 64 && folderName.allSatisfy({ $0.isHexDigit }) {
                targetHashes.insert(folderName)
            }
        }

        guard !targetHashes.isEmpty else { return resolvedByFolderName }

        func testCandidate(_ url: URL) {
            let std = url.standardizedFileURL
            guard AdapterPathNormalizer.isEffectiveDirectory(std, fileSystem: fs) else { return }
            let real = fs.resolveSymlinks(std).standardizedFileURL.path
            let canonical = AdapterPathNormalizer.canonicalIdentityPath(for: std, in: env)
            for repr in Set([real, std.path, canonical]) {
                let digest = ContentHasher.sha256Hex(Data(repr.utf8))
                if targetHashes.contains(digest) && resolvedByFolderName[digest] == nil {
                    resolvedByFolderName[digest] = std.path
                }
            }
        }

        sweepHomeCandidatesForHashMatch(
            under: env.home.standardizedFileURL,
            currentDepth: 0,
            maxDepth: 3,
            fileSystem: fs,
            shouldStop: { targetHashes.allSatisfy { resolvedByFolderName[$0] != nil } },
            visit: testCandidate
        )
        return resolvedByFolderName
    }

    private static func discoverGeminiRepos(
        in env: AgentEnvironment,
        knownRealPaths: [String],
        extraCandidates: [URL],
        record: (URL, RepoDiscoverySource) -> Void
    ) {
        let fs = env.fileSystem
        let tmpRoot = GeminiPathCatalog.userLogsRootDirectory(in: env)
        guard AdapterPathNormalizer.isEffectiveDirectory(tmpRoot, fileSystem: fs),
            let entries = try? fs.list(tmpRoot)
        else {
            return
        }

        var targetHashes: Set<String> = []
        for entry in entries where AdapterPathNormalizer.isEffectiveDirectory(entry, fileSystem: fs) {
            let folderName = entry.lastPathComponent.lowercased()
            // Check `.project_root` plaintext marker written by Gemini CLI Storage if present
            let projectRootMarker = entry.appendingPathComponent(".project_root")
            if AdapterPathNormalizer.isEffectiveFile(projectRootMarker, fileSystem: fs),
                let data = try? fs.contents(at: projectRootMarker),
                let rawPath = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !rawPath.isEmpty
            {
                record(AdapterPathNormalizer.expandHomePrefix(rawPath, in: env), .geminiLogs)
                continue
            }

            if folderName.count == 64 && folderName.allSatisfy({ $0.isHexDigit }) {
                targetHashes.insert(folderName)
            }
        }

        guard !targetHashes.isEmpty else { return }

        var matchedHashes: Set<String> = []

        func testCandidate(_ url: URL) {
            let std = url.standardizedFileURL
            guard AdapterPathNormalizer.isEffectiveDirectory(std, fileSystem: fs) else { return }
            let real = fs.resolveSymlinks(std).standardizedFileURL.path
            let canonical = AdapterPathNormalizer.canonicalIdentityPath(for: std, in: env)

            let representations = Set([real, std.path, canonical])
            for repr in representations {
                let digest = ContentHasher.sha256Hex(Data(repr.utf8))
                if targetHashes.contains(digest) {
                    matchedHashes.insert(digest)
                    record(std, .geminiLogs)
                }
            }
        }

        for realPath in knownRealPaths {
            testCandidate(URL(fileURLWithPath: realPath, isDirectory: true))
        }
        for extra in extraCandidates {
            testCandidate(extra)
        }

        // If any SHA-256 project hash remains unmatched, sweep shallow workspace directories (depth <= 3) under `env.home`.
        if matchedHashes.count < targetHashes.count {
            sweepHomeCandidatesForHashMatch(
                under: env.home.standardizedFileURL,
                currentDepth: 0,
                maxDepth: 3,
                fileSystem: fs,
                shouldStop: { matchedHashes.count == targetHashes.count },
                visit: testCandidate
            )
        }
    }

    private static func sweepHomeCandidatesForHashMatch(
        under directory: URL,
        currentDepth: Int,
        maxDepth: Int,
        fileSystem: any ReadOnlyFileSystem,
        shouldStop: () -> Bool,
        visit: (URL) -> Void
    ) {
        if currentDepth >= maxDepth || shouldStop() {
            return
        }
        guard let children = try? fileSystem.list(directory) else {
            return
        }
        let sorted = children.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in sorted {
            if shouldStop() { return }
            let name = child.lastPathComponent
            if name.hasPrefix(".") || skippedShallowDirectories.contains(name) {
                continue
            }
            guard AdapterPathNormalizer.isEffectiveDirectory(child, fileSystem: fileSystem) else {
                continue
            }
            visit(child)
            sweepHomeCandidatesForHashMatch(
                under: child,
                currentDepth: currentDepth + 1,
                maxDepth: maxDepth,
                fileSystem: fileSystem,
                shouldStop: shouldStop,
                visit: visit
            )
        }
    }

    // MARK: - (4) Copilot CLI

    private static func discoverCopilotRepos(
        in env: AgentEnvironment,
        record: (URL, RepoDiscoverySource) -> Void
    ) {
        let fs = env.fileSystem

        // 4a. `~/.copilot/config.json` -> `trusted_folders` / `trustedDirectories`
        let configFile = CopilotPathCatalog.userConfigFile(in: env)
        if AdapterPathNormalizer.isEffectiveFile(configFile, fileSystem: fs),
            let rawData = try? fs.contents(at: configFile)
        {
            let (settingsDoc, _) = JSONCParser.parseSettings(rawData, redactSecrets: false)
            if let tree = settingsDoc?.tree {
                let folders =
                    (CopilotPayloadParser.stringArray(tree["trusted_folders"]) ?? [])
                    + (CopilotPayloadParser.stringArray(tree["trustedDirectories"]) ?? [])
                for rawPath in folders {
                    record(AdapterPathNormalizer.expandHomePrefix(rawPath, in: env), .copilotConfig)
                }
            }
        }

        // 4b. `~/.copilot/session-state/<id>/{workspace.yaml,events.jsonl}`
        let sessionStateRoot = CopilotPathCatalog.userSessionStateDirectory(in: env)
        guard AdapterPathNormalizer.isEffectiveDirectory(sessionStateRoot, fileSystem: fs),
            let sessionDirs = try? fs.list(sessionStateRoot)
        else {
            return
        }

        for sessionDir in sessionDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where AdapterPathNormalizer.isEffectiveDirectory(sessionDir, fileSystem: fs) {
            if let workspaceCwd = CopilotPayloadParser.parseWorkspaceCwd(in: sessionDir, env: env) {
                record(URL(fileURLWithPath: workspaceCwd, isDirectory: true), .copilotLogs)
            }

            let eventsFile = sessionDir.appendingPathComponent(CopilotPathCatalog.sessionEventsFileName)
            if AdapterPathNormalizer.isEffectiveFile(eventsFile, fileSystem: fs) {
                for cwdURL in extractCwdsFromJSONLPrefix(at: eventsFile, in: env) {
                    record(cwdURL, .copilotLogs)
                }
            }
        }
    }

    // MARK: - (6) Shallow `.git` Scan

    private static func shallowScanGitRepos(
        under root: URL,
        maxDepth: Int,
        fileSystem: any ReadOnlyFileSystem,
        record: (URL, RepoDiscoverySource) -> Void
    ) {
        guard AdapterPathNormalizer.isEffectiveDirectory(root, fileSystem: fileSystem) else {
            return
        }

        var visitedRealDirs: Set<String> = []

        func walk(_ dir: URL, depth: Int) {
            let stdDir = dir.standardizedFileURL
            let realDir = fileSystem.resolveSymlinks(stdDir).standardizedFileURL.path
            guard visitedRealDirs.insert(realDir).inserted else {
                return
            }

            if depth >= 1 && fileSystem.exists(stdDir.appendingPathComponent(".git")) {
                record(stdDir, .shallowScan)
                return
            }

            guard depth < maxDepth, let children = try? fileSystem.list(stdDir) else {
                return
            }

            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = child.lastPathComponent
                if name.hasPrefix(".") || skippedShallowDirectories.contains(name) {
                    continue
                }
                if AdapterPathNormalizer.isEffectiveDirectory(child, fileSystem: fileSystem) {
                    walk(child, depth: depth + 1)
                }
            }
        }

        walk(root, depth: 0)
    }

    // MARK: - Shared JSONL Prefix & Path Helpers

    private static func extractCwdsFromJSONLPrefix(at fileURL: URL, in env: AgentEnvironment) -> [URL] {
        guard let rawData = try? env.fileSystem.contents(at: fileURL), !rawData.isEmpty else {
            return []
        }
        let prefixSlice = rawData.prefix(maxLogInspectBytes)
        guard
            let text = String(data: prefixSlice, encoding: .utf8)
                ?? String(decoding: prefixSlice, as: UTF8.self) as String?
        else {
            return []
        }

        var found: [URL] = []
        var seen: Set<String> = []
        var lineCount = 0

        for lineSub in text.split(whereSeparator: \.isNewline) {
            lineCount += 1
            if lineCount > maxLogInspectLines {
                break
            }
            let trimmed = lineSub.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), trimmed.contains("\"cwd\""),
                let lineData = trimmed.data(using: .utf8),
                let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
            else {
                continue
            }

            var rawCwds: [String] = []
            if let topCwd = obj["cwd"] as? String {
                rawCwds.append(topCwd)
            }
            if let payload = obj["payload"] as? [String: Any], let payloadCwd = payload["cwd"] as? String {
                rawCwds.append(payloadCwd)
            }
            if let context = obj["context"] as? [String: Any], let contextCwd = context["cwd"] as? String {
                rawCwds.append(contextCwd)
            }

            for raw in rawCwds {
                let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { continue }
                let url = AdapterPathNormalizer.expandHomePrefix(clean, in: env)
                if seen.insert(url.path).inserted {
                    found.append(url)
                }
            }
        }

        return found
    }

    private static func normalizeToGitRootIfPresent(
        _ directory: URL,
        stdHome: URL,
        realHome: String,
        fileSystem: any ReadOnlyFileSystem
    ) -> URL {
        var cursor = directory.standardizedFileURL
        while cursor.path != stdHome.path && cursor.path != "/" {
            let realCursor = fileSystem.resolveSymlinks(cursor).standardizedFileURL.path
            if realCursor == realHome {
                break
            }
            if fileSystem.exists(cursor.appendingPathComponent(".git")) {
                return cursor
            }
            let parent = cursor.deletingLastPathComponent().standardizedFileURL
            if parent.path == cursor.path {
                break
            }
            cursor = parent
        }
        return directory.standardizedFileURL
    }

    private static func normalizePathSet(_ rawPaths: Set<String>, in env: AgentEnvironment) -> Set<String> {
        let fs = env.fileSystem
        var out: Set<String> = []
        for raw in rawPaths {
            let expanded = AdapterPathNormalizer.expandHomePrefix(raw, in: env).standardizedFileURL
            out.insert(expanded.path)
            if fs.exists(expanded) {
                out.insert(fs.resolveSymlinks(expanded).standardizedFileURL.path)
            }
        }
        return out
    }
}
