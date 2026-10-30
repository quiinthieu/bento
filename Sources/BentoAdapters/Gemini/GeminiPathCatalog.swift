import BentoCore
import Foundation

/// Single source of truth for all Google Gemini CLI configuration, context, skill, subagent, command,
/// extension, hook, ignore, and log paths, verified against official documentation and `@google/gemini-cli 0.41.2`
/// (`Docs/adapters/gemini.md`).
public enum GeminiPathCatalog: Sendable {
    /// ISO-8601 verification date for all catalog entries.
    public static let verifiedDate = "2026-10-30"

    /// Environment variable overriding the user `.gemini` directory.
    public static let geminiCliHomeEnvKey = "GEMINI_CLI_HOME"
    /// Environment variable overriding the system override `settings.json` path (`Scope.managed`).
    public static let systemSettingsPathEnvKey = "GEMINI_CLI_SYSTEM_SETTINGS_PATH"
    /// Environment variable overriding the system baseline `system-defaults.json` path (`Scope.builtIn`).
    public static let systemDefaultsPathEnvKey = "GEMINI_CLI_SYSTEM_DEFAULTS_PATH"

    private static let configurationDocURL = "https://geminicli.com/docs/reference/configuration"
    private static let settingsDocURL = "https://geminicli.com/docs/cli/settings"
    private static let geminiMdDocURL = "https://geminicli.com/docs/cli/gemini-md"
    private static let mcpDocURL = "https://geminicli.com/docs/tools/mcp-server"
    private static let skillsDocURL = "https://geminicli.com/docs/cli/skills"
    private static let commandsDocURL = "https://geminicli.com/docs/cli/custom-commands"
    private static let subagentsDocURL = "https://geminicli.com/docs/core/subagents"
    private static let extensionsDocURL = "https://geminicli.com/docs/extensions/reference"
    private static let hooksDocURL = "https://geminicli.com/docs/hooks/reference"
    private static let ignoreDocURL = "https://geminicli.com/docs/cli/gemini-ignore"

    // MARK: - Path Components

    private static let managedRelativeDirectory = "Library/Application Support/GeminiCli"
    private static let dotGeminiDirName = ".gemini"
    private static let dotAgentsDirName = ".agents"
    private static let settingsFilename = "settings.json"
    private static let systemDefaultsFilename = "system-defaults.json"
    private static let hooksSubdirName = "hooks"
    private static let hooksFilename = "hooks.json"

    /// Default context/memory Markdown filename when `context.fileName` is omitted.
    public static let defaultContextFilename = "GEMINI.md"
    /// Canonical Markdown filename for skill manifests.
    public static let skillManifestFilename = "SKILL.md"
    /// Project ignore filename for Gemini CLI file exclusions.
    public static let ignoreFilename = ".geminiignore"
    /// Extension manifest filename inside each `~/.gemini/extensions/<name>/` directory.
    public static let extensionManifestFilename = "gemini-extension.json"
    /// Enablement state filename under `~/.gemini/extensions/`.
    public static let extensionEnablementFilename = "extension-enablement.json"

    private static let skillsSubdirName = "skills"
    private static let subagentsSubdirName = "agents"
    private static let commandsSubdirName = "commands"
    private static let extensionsSubdirName = "extensions"
    private static let tmpLogsSubdirName = "tmp"
    private static let chatsSubdirName = "chats"
    private static let sessionFilePrefix = "session-"
    private static let gitMarkerName = ".git"
    private static let finderMetadataFilename = ".DS_Store"

    /// File extension for Gemini TOML custom slash commands.
    public static let commandFileExtension = "toml"
    /// File extension for Markdown subagents and rules.
    public static let markdownFileExtension = "md"

    /// Directory names skipped when scanning descendant project directories for JIT context files.
    public static let skippedDescendantDirectoryNames: Set<String> = [
        gitMarkerName,
        dotGeminiDirName,
        dotAgentsDirName,
        ".claude",
        ".codex",
        ".cursor",
        ".windsurf",
        ".github",
        ".build",
        ".swiftpm",
        "node_modules",
        "DerivedData"
    ]

    /// Complete declarative `PathCatalog` for Google Gemini CLI.
    public static let catalog = PathCatalog(
        entries: [
            PathCatalog.Entry(
                id: "gemini.managed.settings",
                pattern: "/Library/Application Support/GeminiCli/settings.json",
                scope: .managed,
                kind: .settings,
                verifiedAt: verifiedDate,
                docURL: configurationDocURL
            ),
            PathCatalog.Entry(
                id: "gemini.systemDefaults.settings",
                pattern: "/Library/Application Support/GeminiCli/system-defaults.json",
                scope: .builtIn,
                kind: .settings,
                verifiedAt: verifiedDate,
                docURL: configurationDocURL
            ),
            PathCatalog.Entry(
                id: "gemini.user.settings",
                pattern: "~/.gemini/settings.json",
                scope: .user,
                kind: .settings,
                verifiedAt: verifiedDate,
                docURL: settingsDocURL
            ),
            PathCatalog.Entry(
                id: "gemini.user.memory",
                pattern: "~/.gemini/GEMINI.md",
                scope: .user,
                kind: .rules,
                verifiedAt: verifiedDate,
                docURL: geminiMdDocURL
            ),
            PathCatalog.Entry(
                id: "gemini.user.agentsSkills",
                pattern: "~/.agents/skills/*/SKILL.md",
                scope: .user,
                kind: .skill,
                verifiedAt: verifiedDate,
                docURL: skillsDocURL
            ),
            PathCatalog.Entry(
                id: "gemini.user.geminiSkills",
                pattern: "~/.gemini/skills/*/SKILL.md",
                scope: .user,
                kind: .skill,
                verifiedAt: verifiedDate,
                docURL: skillsDocURL
            ),
            PathCatalog.Entry(
                id: "gemini.user.agents",
                pattern: "~/.gemini/agents/**/*.md",
                scope: .user,
                kind: .subagent,
                verifiedAt: verifiedDate,
                docURL: subagentsDocURL
            ),
            PathCatalog.Entry(
                id: "gemini.user.commands",
                pattern: "~/.gemini/commands/**/*.toml",
                scope: .user,
                kind: .command,
                verifiedAt: verifiedDate,
                docURL: commandsDocURL
            ),
            PathCatalog.Entry(
                id: "gemini.user.extensions",
                pattern: "~/.gemini/extensions/*/gemini-extension.json",
                scope: .user,
                kind: .plugin,
                verifiedAt: verifiedDate,
                docURL: extensionsDocURL
            ),
            PathCatalog.Entry(
                id: "gemini.user.logs",
                pattern: "~/.gemini/tmp/*/chats/session-*.json",
                scope: .user,
                kind: .settings,
                verifiedAt: verifiedDate,
                docURL: settingsDocURL
            ),
            PathCatalog.Entry(
                id: "gemini.project.settings",
                pattern: "<repo>/.gemini/settings.json",
                scope: .project,
                kind: .settings,
                verifiedAt: verifiedDate,
                docURL: mcpDocURL
            ),
            PathCatalog.Entry(
                id: "gemini.project.memory",
                pattern: "<repo>/GEMINI.md",
                scope: .project,
                kind: .rules,
                verifiedAt: verifiedDate,
                docURL: geminiMdDocURL
            ),
            PathCatalog.Entry(
                id: "gemini.directory.memory",
                pattern: "<subdir>/GEMINI.md",
                scope: .directory,
                kind: .rules,
                verifiedAt: verifiedDate,
                docURL: geminiMdDocURL
            ),
            PathCatalog.Entry(
                id: "gemini.project.ignore",
                pattern: "<repo>/.geminiignore",
                scope: .project,
                kind: .ignoreFile,
                verifiedAt: verifiedDate,
                docURL: ignoreDocURL
            ),
            PathCatalog.Entry(
                id: "gemini.project.agentsSkills",
                pattern: "<repo>/.agents/skills/*/SKILL.md",
                scope: .project,
                kind: .skill,
                verifiedAt: verifiedDate,
                docURL: skillsDocURL
            ),
            PathCatalog.Entry(
                id: "gemini.project.geminiSkills",
                pattern: "<repo>/.gemini/skills/*/SKILL.md",
                scope: .project,
                kind: .skill,
                verifiedAt: verifiedDate,
                docURL: skillsDocURL
            ),
            PathCatalog.Entry(
                id: "gemini.project.agents",
                pattern: "<repo>/.gemini/agents/**/*.md",
                scope: .project,
                kind: .subagent,
                verifiedAt: verifiedDate,
                docURL: subagentsDocURL
            ),
            PathCatalog.Entry(
                id: "gemini.project.commands",
                pattern: "<repo>/.gemini/commands/**/*.toml",
                scope: .project,
                kind: .command,
                verifiedAt: verifiedDate,
                docURL: commandsDocURL
            )
        ]
    )

    // MARK: - Managed & System-Default Paths

    /// System-managed Gemini CLI directory (`/Library/Application Support/GeminiCli` under `BENTO_SYSTEM_ROOT` or `/`).
    public static func managedSystemDirectory(in env: AgentEnvironment) -> URL {
        AdapterPathNormalizer.systemRootURL(in: env)
            .appendingPathComponent(managedRelativeDirectory, isDirectory: true)
            .standardizedFileURL
    }

    /// System override `settings.json` (`GEMINI_CLI_SYSTEM_SETTINGS_PATH` when set, else `/Library/Application Support/GeminiCli/settings.json`).
    public static func managedSettingsFile(in env: AgentEnvironment) -> URL {
        if let raw = env.env[systemSettingsPathEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        {
            return AdapterPathNormalizer.expandHomePrefix(raw, in: env)
        }
        return managedSystemDirectory(in: env).appendingPathComponent(settingsFilename)
    }

    /// System baseline `system-defaults.json` (`GEMINI_CLI_SYSTEM_DEFAULTS_PATH` when set, else `/Library/Application Support/GeminiCli/system-defaults.json`).
    public static func systemDefaultsFile(in env: AgentEnvironment) -> URL {
        if let raw = env.env[systemDefaultsPathEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        {
            return AdapterPathNormalizer.expandHomePrefix(raw, in: env)
        }
        return managedSystemDirectory(in: env).appendingPathComponent(systemDefaultsFilename)
    }

    // MARK: - User Paths

    /// Effective user `.gemini` directory (`GEMINI_CLI_HOME` when set, otherwise `<home>/.gemini`).
    /// If `GEMINI_CLI_HOME` points to a parent folder containing `.gemini/`, uses `<GEMINI_CLI_HOME>/.gemini`.
    public static func userGeminiDirectory(in env: AgentEnvironment) -> URL {
        if let raw = env.env[geminiCliHomeEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        {
            let expanded = AdapterPathNormalizer.expandHomePrefix(raw, in: env).standardizedFileURL
            if expanded.lastPathComponent != dotGeminiDirName {
                let nested = expanded.appendingPathComponent(dotGeminiDirName, isDirectory: true).standardizedFileURL
                if AdapterPathNormalizer.isEffectiveDirectory(nested, fileSystem: env.fileSystem) {
                    return nested
                }
            }
            return expanded
        }
        return env.home.appendingPathComponent(dotGeminiDirName, isDirectory: true).standardizedFileURL
    }

    /// User `settings.json` inside the effective user Gemini directory.
    public static func userSettingsFile(in env: AgentEnvironment) -> URL {
        userGeminiDirectory(in: env).appendingPathComponent(settingsFilename)
    }

    /// Cross-agent user skills directory `<home>/.agents/skills`.
    public static func userAgentsSkillsDirectory(in env: AgentEnvironment) -> URL {
        env.home
            .appendingPathComponent(dotAgentsDirName, isDirectory: true)
            .appendingPathComponent(skillsSubdirName, isDirectory: true)
            .standardizedFileURL
    }

    /// User Gemini skills directory `<GEMINI_CLI_HOME>/skills`.
    public static func userGeminiSkillsDirectory(in env: AgentEnvironment) -> URL {
        userGeminiDirectory(in: env)
            .appendingPathComponent(skillsSubdirName, isDirectory: true)
            .standardizedFileURL
    }

    /// User subagents directory `<GEMINI_CLI_HOME>/agents`.
    public static func userSubagentsDirectory(in env: AgentEnvironment) -> URL {
        userGeminiDirectory(in: env)
            .appendingPathComponent(subagentsSubdirName, isDirectory: true)
            .standardizedFileURL
    }

    /// User custom TOML commands directory `<GEMINI_CLI_HOME>/commands`.
    public static func userCommandsDirectory(in env: AgentEnvironment) -> URL {
        userGeminiDirectory(in: env)
            .appendingPathComponent(commandsSubdirName, isDirectory: true)
            .standardizedFileURL
    }

    /// Installed Gemini CLI extensions directory `<GEMINI_CLI_HOME>/extensions`.
    public static func userExtensionsDirectory(in env: AgentEnvironment) -> URL {
        userGeminiDirectory(in: env)
            .appendingPathComponent(extensionsSubdirName, isDirectory: true)
            .standardizedFileURL
    }

    /// Extension enablement state file `<GEMINI_CLI_HOME>/extensions/extension-enablement.json`.
    public static func extensionEnablementFile(in env: AgentEnvironment) -> URL {
        userExtensionsDirectory(in: env).appendingPathComponent(extensionEnablementFilename)
    }

    /// User temporary/session logs root `<GEMINI_CLI_HOME>/tmp`.
    public static func userLogsRootDirectory(in env: AgentEnvironment) -> URL {
        userGeminiDirectory(in: env)
            .appendingPathComponent(tmpLogsSubdirName, isDirectory: true)
            .standardizedFileURL
    }

    // MARK: - Extension Bundle Paths

    /// `<extensionDir>/gemini-extension.json`.
    public static func extensionManifestFile(in extensionDir: URL) -> URL {
        extensionDir.appendingPathComponent(extensionManifestFilename).standardizedFileURL
    }

    /// `<extensionDir>/skills`.
    public static func extensionSkillsDirectory(in extensionDir: URL) -> URL {
        extensionDir.appendingPathComponent(skillsSubdirName, isDirectory: true).standardizedFileURL
    }

    /// `<extensionDir>/agents`.
    public static func extensionSubagentsDirectory(in extensionDir: URL) -> URL {
        extensionDir.appendingPathComponent(subagentsSubdirName, isDirectory: true).standardizedFileURL
    }

    /// `<extensionDir>/commands`.
    public static func extensionCommandsDirectory(in extensionDir: URL) -> URL {
        extensionDir.appendingPathComponent(commandsSubdirName, isDirectory: true).standardizedFileURL
    }

    /// `<extensionDir>/hooks/hooks.json`.
    public static func extensionHooksFile(in extensionDir: URL) -> URL {
        extensionDir
            .appendingPathComponent(hooksSubdirName, isDirectory: true)
            .appendingPathComponent(hooksFilename)
            .standardizedFileURL
    }

    // MARK: - Project & Directory Paths

    /// `<directory>/.gemini/settings.json`.
    public static func directorySettingsFile(in directory: URL) -> URL {
        directory
            .appendingPathComponent(dotGeminiDirName, isDirectory: true)
            .appendingPathComponent(settingsFilename)
            .standardizedFileURL
    }

    /// `<directory>/.geminiignore`.
    public static func directoryIgnoreFile(in directory: URL) -> URL {
        directory.appendingPathComponent(ignoreFilename).standardizedFileURL
    }

    /// `<directory>/.agents/skills`.
    public static func directoryAgentsSkillsDirectory(in directory: URL) -> URL {
        directory
            .appendingPathComponent(dotAgentsDirName, isDirectory: true)
            .appendingPathComponent(skillsSubdirName, isDirectory: true)
            .standardizedFileURL
    }

    /// `<directory>/.gemini/skills`.
    public static func directoryGeminiSkillsDirectory(in directory: URL) -> URL {
        directory
            .appendingPathComponent(dotGeminiDirName, isDirectory: true)
            .appendingPathComponent(skillsSubdirName, isDirectory: true)
            .standardizedFileURL
    }

    /// `<directory>/.gemini/agents`.
    public static func directorySubagentsDirectory(in directory: URL) -> URL {
        directory
            .appendingPathComponent(dotGeminiDirName, isDirectory: true)
            .appendingPathComponent(subagentsSubdirName, isDirectory: true)
            .standardizedFileURL
    }

    /// `<directory>/.gemini/commands`.
    public static func directoryCommandsDirectory(in directory: URL) -> URL {
        directory
            .appendingPathComponent(dotGeminiDirName, isDirectory: true)
            .appendingPathComponent(commandsSubdirName, isDirectory: true)
            .standardizedFileURL
    }

    // MARK: - Classification & Label Helpers

    /// Returns `true` when `directory` contains a `.git` file or folder.
    public static func hasGitMarker(in directory: URL, fileSystem: any ReadOnlyFileSystem) -> Bool {
        fileSystem.exists(directory.appendingPathComponent(gitMarkerName))
    }

    /// Returns `true` when `directory` contains Gemini CLI workspace root markers.
    public static func hasGeminiRootMarkers(in directory: URL, fileSystem: any ReadOnlyFileSystem) -> Bool {
        let markers = [
            directory.appendingPathComponent(dotGeminiDirName),
            directory.appendingPathComponent(dotAgentsDirName),
            directory.appendingPathComponent(ignoreFilename),
            directory.appendingPathComponent(defaultContextFilename)
        ]
        return markers.contains { fileSystem.exists($0) }
    }

    /// Returns `true` when `path` resides under an `.agents/skills/` tree (higher tie-break priority than `.gemini/skills/`).
    public static func isAgentsAliasSkillPath(_ path: String) -> Bool {
        path.contains("/\(dotAgentsDirName)/\(skillsSubdirName)/")
    }

    /// Returns `true` when `path` resides inside `<GEMINI_CLI_HOME>/extensions/`.
    public static func isExtensionArtifactPath(_ path: String, in env: AgentEnvironment) -> Bool {
        let stdPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let extRoot = userExtensionsDirectory(in: env).standardizedFileURL.path
        if stdPath.hasPrefix(extRoot + "/") {
            return true
        }
        return stdPath.contains("/\(dotGeminiDirName)/\(extensionsSubdirName)/")
    }

    /// Extracts the extension folder name if `path` resides inside `<GEMINI_CLI_HOME>/extensions/<name>/...`.
    public static func extensionName(forPath path: String, in env: AgentEnvironment) -> String? {
        let stdPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let extRoot = userExtensionsDirectory(in: env).standardizedFileURL.path
        if stdPath.hasPrefix(extRoot + "/") {
            let remainder = String(stdPath.dropFirst(extRoot.count + 1))
            return remainder.split(separator: "/").first.map(String.init)
        }
        let marker = "/\(dotGeminiDirName)/\(extensionsSubdirName)/"
        if let range = stdPath.range(of: marker) {
            let remainder = String(stdPath[range.upperBound...])
            return remainder.split(separator: "/").first.map(String.init)
        }
        return nil
    }

    /// Returns `true` when `url` is a Gemini CLI chat transcript (`.../chats/session-*.json[l][.zst]`).
    public static func isSessionLogFile(_ url: URL) -> Bool {
        let parentName = url.deletingLastPathComponent().lastPathComponent
        guard parentName == chatsSubdirName else { return false }
        let filename = url.lastPathComponent
        guard filename.hasPrefix(sessionFilePrefix) else { return false }
        let lower = filename.lowercased()
        return lower.hasSuffix(".json")
            || lower.hasSuffix(".jsonl")
            || lower.hasSuffix(".json.zst")
            || lower.hasSuffix(".jsonl.zst")
    }

    /// Returns `true` when `url` is zstd-compressed.
    public static func isCompressedLogFile(_ url: URL) -> Bool {
        url.path.lowercased().hasSuffix(".zst")
    }

    /// Returns `true` for macOS Finder metadata files excluded from skill supporting file lists.
    public static func isFinderMetadataFile(_ url: URL) -> Bool {
        url.lastPathComponent == finderMetadataFilename
    }

    /// Human-readable source label for `Resolution` and `ShadowRecord` explanations.
    public static func humanSourceLabel(for path: String, scope: Scope, in env: AgentEnvironment) -> String {
        let filename = URL(fileURLWithPath: path).lastPathComponent
        if let extName = extensionName(forPath: path, in: env) {
            return "extension '\(extName)' (\(filename))"
        }

        switch scope {
        case .managed:
            return "/\(managedRelativeDirectory)/\(filename)"
        case .builtIn:
            return "/\(managedRelativeDirectory)/\(filename)"
        case .user:
            if isAgentsAliasSkillPath(path) {
                return "~/\(dotAgentsDirName)/\(skillsSubdirName)"
            }
            let geminiDir = userGeminiDirectory(in: env).standardizedFileURL.path
            if path.hasPrefix(geminiDir + "/") {
                let rel = String(path.dropFirst(geminiDir.count + 1))
                return "~/\(dotGeminiDirName)/\(rel)"
            }
            return "~/\(dotGeminiDirName)/\(filename)"
        case .project:
            if isAgentsAliasSkillPath(path) {
                return "project \(dotAgentsDirName)/\(skillsSubdirName)"
            }
            if path.contains("/\(dotGeminiDirName)/") {
                return "project \(dotGeminiDirName)/\(filename)"
            }
            return "project \(filename)"
        case .directory:
            if path.contains("/\(dotGeminiDirName)/") {
                return "directory \(dotGeminiDirName)/\(filename)"
            }
            return "directory \(filename)"
        case .projectLocal:
            return "local \(filename)"
        }
    }
}
