import BentoCore
import Foundation

/// Shared path normalization and cycle-safe read-only directory traversal utilities for `BentoAdapters`.
/// All operations use the injected `AgentEnvironment` and `ReadOnlyFileSystem`, never touching real `$HOME`.
public enum AdapterPathNormalizer: Sendable {
    /// Environment variable overriding the root prefix for system-managed config directories (`/Library/...`, `/etc/...`).
    public static let systemRootEnvKey = "BENTO_SYSTEM_ROOT"

    /// Canonicalizes `url` relative to `env.home` (`<HOME>/...`) so `ArtifactID` hashes remain stable
    /// across developer checkouts, CI runners, and temporary fixture copies.
    public static func canonicalIdentityPath(for url: URL, in env: AgentEnvironment) -> String {
        let standardizedPath = url.standardizedFileURL.path
        let rawHome = env.home.standardizedFileURL.path
        let resolvedHome = env.fileSystem.resolveSymlinks(env.home).standardizedFileURL.path

        let prefixes = Set([rawHome, resolvedHome])
            .filter { !$0.isEmpty && $0 != "/" }
            .sorted { $0.count > $1.count }

        for prefix in prefixes {
            if standardizedPath == prefix {
                return "<HOME>"
            }
            if standardizedPath.hasPrefix(prefix + "/") {
                return "<HOME>" + standardizedPath.dropFirst(prefix.count)
            }
        }

        let resolvedTarget = env.fileSystem.resolveSymlinks(url).standardizedFileURL.path
        for prefix in prefixes {
            if resolvedTarget == prefix {
                return "<HOME>"
            }
            if resolvedTarget.hasPrefix(prefix + "/") {
                return "<HOME>" + resolvedTarget.dropFirst(prefix.count)
            }
        }

        return standardizedPath
    }

    /// Expands leading `~`, `~/`, or `<HOME>/` against `env.home` without ever querying real `$HOME`.
    public static func expandHomePrefix(_ rawPath: String, in env: AgentEnvironment) -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" || trimmed == "<HOME>" {
            return env.home.standardizedFileURL
        }
        if trimmed.hasPrefix("~/") {
            let suffix = String(trimmed.dropFirst(2))
            return env.home.appendingPathComponent(suffix).standardizedFileURL
        }
        if trimmed.hasPrefix("<HOME>/") {
            let suffix = String(trimmed.dropFirst("<HOME>/".count))
            return env.home.appendingPathComponent(suffix).standardizedFileURL
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }
        return env.home.appendingPathComponent(trimmed).standardizedFileURL
    }

    /// Resolves the effective system root URL (`/` in production, or `BENTO_SYSTEM_ROOT` in hermetic tests).
    public static func systemRootURL(in env: AgentEnvironment) -> URL {
        if let override = env.env[systemRootEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return expandHomePrefix(override, in: env)
        }
        return URL(fileURLWithPath: "/", isDirectory: true)
    }

    /// Builds a `SourceLocation` for `url` using `env.fileSystem.resolveSymlinks`.
    public static func sourceLocation(
        for url: URL,
        keyPath: [String]? = nil,
        lineRange: ClosedRange<Int>? = nil,
        in env: AgentEnvironment
    ) -> SourceLocation {
        let standardized = url.standardizedFileURL
        let resolved = env.fileSystem.resolveSymlinks(standardized).standardizedFileURL
        return SourceLocation(
            path: standardized.path,
            realPath: resolved.path,
            keyPath: keyPath,
            lineRange: lineRange
        )
    }

    /// Returns `true` when `url` is a directory or a symbolic link targeting a directory.
    public static func isEffectiveDirectory(_ url: URL, fileSystem: any ReadOnlyFileSystem) -> Bool {
        guard let attrs = try? fileSystem.attributes(url) else {
            return false
        }
        if attrs.isDirectory {
            return true
        }
        if attrs.isSymlink {
            let target = fileSystem.resolveSymlinks(url)
            return (try? fileSystem.attributes(target).isDirectory) == true
        }
        return false
    }

    /// Returns `true` when `url` exists and resolves to a non-directory regular file.
    public static func isEffectiveFile(_ url: URL, fileSystem: any ReadOnlyFileSystem) -> Bool {
        guard fileSystem.exists(url) else {
            return false
        }
        return !isEffectiveDirectory(url, fileSystem: fileSystem)
    }

    /// Cycle-safe, deterministically sorted recursive file collector operating strictly through `ReadOnlyFileSystem`.
    public static func collectFilesRecursively(
        under root: URL,
        skippingDirectoryNames: Set<String> = [],
        fileSystem: any ReadOnlyFileSystem,
        where predicate: (URL) -> Bool = { _ in true }
    ) -> [URL] {
        guard isEffectiveDirectory(root, fileSystem: fileSystem) else {
            return []
        }

        var visitedRealDirectories: Set<String> = []
        var collected: [URL] = []

        func walk(_ directory: URL) {
            let standardizedDir = directory.standardizedFileURL
            let realDirPath = fileSystem.resolveSymlinks(standardizedDir).standardizedFileURL.path
            guard visitedRealDirectories.insert(realDirPath).inserted else {
                return
            }

            guard let entries = try? fileSystem.list(standardizedDir) else {
                return
            }

            let sortedEntries = entries.sorted {
                $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8)
            }

            for entry in sortedEntries {
                let name = entry.lastPathComponent
                if isEffectiveDirectory(entry, fileSystem: fileSystem) {
                    if skippingDirectoryNames.contains(name) {
                        continue
                    }
                    walk(entry)
                } else if isEffectiveFile(entry, fileSystem: fileSystem), predicate(entry) {
                    collected.append(entry.standardizedFileURL)
                }
            }
        }

        walk(root)
        return collected
    }

    /// Computes the slash-separated relative path of `target` inside `base`, or `nil` if `target` is outside `base`.
    public static func relativePath(
        of target: URL,
        from base: URL,
        fileSystem: any ReadOnlyFileSystem
    ) -> String? {
        let stdTarget = target.standardizedFileURL.path
        let stdBase = base.standardizedFileURL.path
        if stdTarget == stdBase {
            return ""
        }
        if stdTarget.hasPrefix(stdBase + "/") {
            return String(stdTarget.dropFirst(stdBase.count + 1))
        }

        let realTarget = fileSystem.resolveSymlinks(target).standardizedFileURL.path
        let realBase = fileSystem.resolveSymlinks(base).standardizedFileURL.path
        if realTarget == realBase {
            return ""
        }
        if realTarget.hasPrefix(realBase + "/") {
            return String(realTarget.dropFirst(realBase.count + 1))
        }
        return nil
    }
}
