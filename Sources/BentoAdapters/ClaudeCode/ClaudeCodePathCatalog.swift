import BentoCore
import Foundation

/// Single source of truth for all Claude Code configuration, plugin, and log paths,
/// verified against official documentation (`Docs/adapters/claude-code.md`).
public enum ClaudeCodePathCatalog: Sendable {
    /// ISO-8601 verification date for all catalog entries.
    public static let verifiedDate = "2026-10-30"

    /// Environment variable overriding the user `.claude` directory.
    public static let configDirEnvKey = "CLAUDE_CONFIG_DIR"

    private static let settingsDocURL = "https://code.claude.com/docs/en/settings"
    private static let memoryDocURL = "https://code.claude.com/docs/en/memory"
    private static let mcpDocURL = "https://code.claude.com/docs/en/mcp"
    private static let skillsDocURL = "https://code.claude.com/docs/en/skills"
    private static let subagentsDocURL = "https://code.claude.com/docs/en/sub-agents"
    private static let commandsDocURL = "https://code.claude.com/docs/en/slash-commands"
    private static let pluginsDocURL = "https://code.claude.com/docs/en/plugins"

    // MARK: - Path Components

    private static let managedRelativeDirectory = "Library/Application Support/ClaudeCode"
    private static let managedSettingsFilename = "managed-settings.json"
    private static let managedMCPFilename = "managed-mcp.json"

    private static let dotClaudeDirName = ".claude"
    private static let userStateFilename = ".claude.json"
    private static let settingsFilename = "settings.json"
    private static let settingsLocalFilename = "settings.local.json"
    private static let projectMCPFilename = ".mcp.json"

    /// Canonical Markdown filename for Claude memory files.
    public static let memoryFilename = "CLAUDE.md"
    /// Canonical Markdown filename for local gitignored Claude memory files.
    public static let localMemoryFilename = "CLAUDE.local.md"
    /// Canonical Markdown filename for skill manifests.
    public static let skillManifestFilename = "SKILL.md"

    private static let rulesSubdirName = "rules"
    private static let skillsSubdirName = "skills"
    private static let agentsSubdirName = "agents"
    private static let commandsSubdirName = "commands"
    private static let pluginsSubdirName = "plugins"
    private static let pluginsCacheSubdirName = "cache"
    private static let installedPluginsFilename = "installed_plugins.json"
    private static let pluginMetaDirName = ".claude-plugin"
    private static let pluginManifestFilename = "plugin.json"
    private static let hooksSubdirName = "hooks"
    private static let pluginHooksFilename = "hooks.json"
    private static let projectsLogsSubdirName = "projects"
    private static let gitMarkerName = ".git"

    /// Directory names skipped when scanning descendant project directories for nested memory files.
    public static let skippedDescendantDirectoryNames: Set<String> = [
        gitMarkerName,
        dotClaudeDirName,
        ".build",
        ".swiftpm",
        "node_modules",
        "DerivedData"
    ]

    /// Complete declarative `PathCatalog` for Claude Code.
    public static let catalog = PathCatalog(
        entries: [
            PathCatalog.Entry(
                id: "claude.managed.settings",
                pattern: "/Library/Application Support/ClaudeCode/managed-settings.json",
                scope: .managed,
                kind: .settings,
                verifiedAt: verifiedDate,
                docURL: settingsDocURL
            ),
            PathCatalog.Entry(
                id: "claude.managed.mcp",
                pattern: "/Library/Application Support/ClaudeCode/managed-mcp.json",
                scope: .managed,
                kind: .mcpServer,
                verifiedAt: verifiedDate,
                docURL: mcpDocURL
            ),
            PathCatalog.Entry(
                id: "claude.managed.memory",
                pattern: "/Library/Application Support/ClaudeCode/CLAUDE.md",
                scope: .managed,
                kind: .rules,
                verifiedAt: verifiedDate,
                docURL: memoryDocURL
            ),
            PathCatalog.Entry(
                id: "claude.user.settings",
                pattern: "~/.claude/settings.json",
                scope: .user,
                kind: .settings,
                verifiedAt: verifiedDate,
                docURL: settingsDocURL
            ),
            PathCatalog.Entry(
                id: "claude.user.state",
                pattern: "~/.claude.json",
                scope: .user,
                kind: .mcpServer,
                verifiedAt: verifiedDate,
                docURL: mcpDocURL
            ),
            PathCatalog.Entry(
                id: "claude.user.memory",
                pattern: "~/.claude/CLAUDE.md",
                scope: .user,
                kind: .rules,
                verifiedAt: verifiedDate,
                docURL: memoryDocURL
            ),
            PathCatalog.Entry(
                id: "claude.user.rules",
                pattern: "~/.claude/rules/**/*.md",
                scope: .user,
                kind: .rules,
                verifiedAt: verifiedDate,
                docURL: memoryDocURL
            ),
            PathCatalog.Entry(
                id: "claude.user.skills",
                pattern: "~/.claude/skills/*/SKILL.md",
                scope: .user,
                kind: .skill,
                verifiedAt: verifiedDate,
                docURL: skillsDocURL
            ),
            PathCatalog.Entry(
                id: "claude.user.agents",
                pattern: "~/.claude/agents/**/*.md",
                scope: .user,
                kind: .subagent,
                verifiedAt: verifiedDate,
                docURL: subagentsDocURL
            ),
            PathCatalog.Entry(
                id: "claude.user.commands",
                pattern: "~/.claude/commands/**/*.md",
                scope: .user,
                kind: .command,
                verifiedAt: verifiedDate,
                docURL: commandsDocURL
            ),
            PathCatalog.Entry(
                id: "claude.user.plugins.registry",
                pattern: "~/.claude/plugins/installed_plugins.json",
                scope: .user,
                kind: .plugin,
                verifiedAt: verifiedDate,
                docURL: pluginsDocURL
            ),
            PathCatalog.Entry(
                id: "claude.user.plugins.manifest",
                pattern: "~/.claude/plugins/cache/**/.claude-plugin/plugin.json",
                scope: .user,
                kind: .plugin,
                verifiedAt: verifiedDate,
                docURL: pluginsDocURL
            ),
            PathCatalog.Entry(
                id: "claude.user.logs",
                pattern: "~/.claude/projects/**/*.jsonl",
                scope: .user,
                kind: .settings,
                verifiedAt: verifiedDate,
                docURL: settingsDocURL
            ),
            PathCatalog.Entry(
                id: "claude.project.settings",
                pattern: "<repo>/.claude/settings.json",
                scope: .project,
                kind: .settings,
                verifiedAt: verifiedDate,
                docURL: settingsDocURL
            ),
            PathCatalog.Entry(
                id: "claude.project.settingsLocal",
                pattern: "<repo>/.claude/settings.local.json",
                scope: .projectLocal,
                kind: .settings,
                verifiedAt: verifiedDate,
                docURL: settingsDocURL
            ),
            PathCatalog.Entry(
                id: "claude.project.mcp",
                pattern: "<repo>/.mcp.json",
                scope: .project,
                kind: .mcpServer,
                verifiedAt: verifiedDate,
                docURL: mcpDocURL
            ),
            PathCatalog.Entry(
                id: "claude.project.memoryRoot",
                pattern: "<repo>/CLAUDE.md",
                scope: .project,
                kind: .rules,
                verifiedAt: verifiedDate,
                docURL: memoryDocURL
            ),
            PathCatalog.Entry(
                id: "claude.project.memoryDotClaude",
                pattern: "<repo>/.claude/CLAUDE.md",
                scope: .project,
                kind: .rules,
                verifiedAt: verifiedDate,
                docURL: memoryDocURL
            ),
            PathCatalog.Entry(
                id: "claude.project.memoryLocal",
                pattern: "<repo>/CLAUDE.local.md",
                scope: .projectLocal,
                kind: .rules,
                verifiedAt: verifiedDate,
                docURL: memoryDocURL
            ),
            PathCatalog.Entry(
                id: "claude.project.rules",
                pattern: "<repo>/.claude/rules/**/*.md",
                scope: .project,
                kind: .rules,
                verifiedAt: verifiedDate,
                docURL: memoryDocURL
            ),
            PathCatalog.Entry(
                id: "claude.project.skills",
                pattern: "<repo>/.claude/skills/*/SKILL.md",
                scope: .project,
                kind: .skill,
                verifiedAt: verifiedDate,
                docURL: skillsDocURL
            ),
            PathCatalog.Entry(
                id: "claude.project.agents",
                pattern: "<repo>/.claude/agents/**/*.md",
                scope: .project,
                kind: .subagent,
                verifiedAt: verifiedDate,
                docURL: subagentsDocURL
            ),
            PathCatalog.Entry(
                id: "claude.project.commands",
                pattern: "<repo>/.claude/commands/**/*.md",
                scope: .project,
                kind: .command,
                verifiedAt: verifiedDate,
                docURL: commandsDocURL
            ),
            PathCatalog.Entry(
                id: "claude.directory.memory",
                pattern: "<subdir>/CLAUDE.md",
                scope: .directory,
                kind: .rules,
                verifiedAt: verifiedDate,
                docURL: memoryDocURL
            )
        ]
    )

    // MARK: - Managed Paths

    /// Enterprise-managed Claude Code directory (`/Library/Application Support/ClaudeCode` under system root).
    public static func managedDirectory(in env: AgentEnvironment) -> URL {
        AdapterPathNormalizer.systemRootURL(in: env)
            .appendingPathComponent(managedRelativeDirectory, isDirectory: true)
            .standardizedFileURL
    }

    public static func managedSettingsFile(in env: AgentEnvironment) -> URL {
        managedDirectory(in: env).appendingPathComponent(managedSettingsFilename)
    }

    public static func managedMCPFile(in env: AgentEnvironment) -> URL {
        managedDirectory(in: env).appendingPathComponent(managedMCPFilename)
    }

    public static func managedMemoryFile(in env: AgentEnvironment) -> URL {
        managedDirectory(in: env).appendingPathComponent(memoryFilename)
    }

    public static func managedSkillsDirectory(in env: AgentEnvironment) -> URL {
        managedDirectory(in: env).appendingPathComponent(skillsSubdirName, isDirectory: true)
    }

    public static func managedAgentsDirectory(in env: AgentEnvironment) -> URL {
        managedDirectory(in: env).appendingPathComponent(agentsSubdirName, isDirectory: true)
    }

    // MARK: - User Paths

    /// Effective user configuration root (`CLAUDE_CONFIG_DIR` when set, else `<home>/.claude`).
    public static func userConfigDirectory(in env: AgentEnvironment) -> URL {
        if let override = env.env[configDirEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return AdapterPathNormalizer.expandHomePrefix(override, in: env)
        }
        return env.home.appendingPathComponent(dotClaudeDirName, isDirectory: true).standardizedFileURL
    }

    /// Effective user state file (`<CLAUDE_CONFIG_DIR>/.claude.json` if present when overridden, else `<home>/.claude.json`).
    public static func userStateFile(in env: AgentEnvironment) -> URL {
        if let override = env.env[configDirEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            let relocated = AdapterPathNormalizer.expandHomePrefix(override, in: env)
                .appendingPathComponent(userStateFilename)
                .standardizedFileURL
            if env.fileSystem.exists(relocated) {
                return relocated
            }
        }
        return env.home.appendingPathComponent(userStateFilename).standardizedFileURL
    }

    public static func userSettingsFile(in env: AgentEnvironment) -> URL {
        userConfigDirectory(in: env).appendingPathComponent(settingsFilename)
    }

    public static func userMemoryFile(in env: AgentEnvironment) -> URL {
        userConfigDirectory(in: env).appendingPathComponent(memoryFilename)
    }

    public static func userRulesDirectory(in env: AgentEnvironment) -> URL {
        userConfigDirectory(in: env).appendingPathComponent(rulesSubdirName, isDirectory: true)
    }

    public static func userSkillsDirectory(in env: AgentEnvironment) -> URL {
        userConfigDirectory(in: env).appendingPathComponent(skillsSubdirName, isDirectory: true)
    }

    public static func userAgentsDirectory(in env: AgentEnvironment) -> URL {
        userConfigDirectory(in: env).appendingPathComponent(agentsSubdirName, isDirectory: true)
    }

    public static func userCommandsDirectory(in env: AgentEnvironment) -> URL {
        userConfigDirectory(in: env).appendingPathComponent(commandsSubdirName, isDirectory: true)
    }

    public static func userPluginsRegistryFile(in env: AgentEnvironment) -> URL {
        userConfigDirectory(in: env)
            .appendingPathComponent(pluginsSubdirName, isDirectory: true)
            .appendingPathComponent(installedPluginsFilename)
    }

    public static func userPluginsCacheDirectory(in env: AgentEnvironment) -> URL {
        userConfigDirectory(in: env)
            .appendingPathComponent(pluginsSubdirName, isDirectory: true)
            .appendingPathComponent(pluginsCacheSubdirName, isDirectory: true)
    }

    public static func userLogsDirectory(in env: AgentEnvironment) -> URL {
        userConfigDirectory(in: env).appendingPathComponent(projectsLogsSubdirName, isDirectory: true)
    }

    // MARK: - Project & Directory Paths

    public static func projectDotClaudeDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent(dotClaudeDirName, isDirectory: true).standardizedFileURL
    }

    public static func projectSettingsFile(in repoRoot: URL) -> URL {
        projectDotClaudeDirectory(in: repoRoot).appendingPathComponent(settingsFilename)
    }

    public static func projectLocalSettingsFile(in repoRoot: URL) -> URL {
        projectDotClaudeDirectory(in: repoRoot).appendingPathComponent(settingsLocalFilename)
    }

    public static func projectMCPFile(in repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(projectMCPFilename).standardizedFileURL
    }

    public static func memoryFile(in directory: URL) -> URL {
        directory.appendingPathComponent(memoryFilename).standardizedFileURL
    }

    public static func dotClaudeMemoryFile(in directory: URL) -> URL {
        projectDotClaudeDirectory(in: directory).appendingPathComponent(memoryFilename)
    }

    public static func localMemoryFile(in directory: URL) -> URL {
        directory.appendingPathComponent(localMemoryFilename).standardizedFileURL
    }

    public static func projectRulesDirectory(in repoRoot: URL) -> URL {
        projectDotClaudeDirectory(in: repoRoot).appendingPathComponent(rulesSubdirName, isDirectory: true)
    }

    public static func projectSkillsDirectory(in repoRoot: URL) -> URL {
        projectDotClaudeDirectory(in: repoRoot).appendingPathComponent(skillsSubdirName, isDirectory: true)
    }

    public static func projectAgentsDirectory(in repoRoot: URL) -> URL {
        projectDotClaudeDirectory(in: repoRoot).appendingPathComponent(agentsSubdirName, isDirectory: true)
    }

    public static func projectCommandsDirectory(in repoRoot: URL) -> URL {
        projectDotClaudeDirectory(in: repoRoot).appendingPathComponent(commandsSubdirName, isDirectory: true)
    }

    public static func skillManifestFile(in skillDirectory: URL) -> URL {
        skillDirectory.appendingPathComponent(skillManifestFilename).standardizedFileURL
    }

    // MARK: - Plugin Bundle Paths

    public static func pluginManifestFile(in pluginDirectory: URL) -> URL {
        pluginDirectory
            .appendingPathComponent(pluginMetaDirName, isDirectory: true)
            .appendingPathComponent(pluginManifestFilename)
            .standardizedFileURL
    }

    public static func isPluginManifestURL(_ url: URL) -> Bool {
        url.lastPathComponent == pluginManifestFilename
            && url.deletingLastPathComponent().lastPathComponent == pluginMetaDirName
    }

    public static func pluginRootDirectory(forManifestURL manifestURL: URL) -> URL {
        manifestURL.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
    }

    public static func pluginSkillsDirectory(in pluginDirectory: URL) -> URL {
        pluginDirectory.appendingPathComponent(skillsSubdirName, isDirectory: true).standardizedFileURL
    }

    public static func pluginAgentsDirectory(in pluginDirectory: URL) -> URL {
        pluginDirectory.appendingPathComponent(agentsSubdirName, isDirectory: true).standardizedFileURL
    }

    public static func pluginCommandsDirectory(in pluginDirectory: URL) -> URL {
        pluginDirectory.appendingPathComponent(commandsSubdirName, isDirectory: true).standardizedFileURL
    }

    public static func pluginHooksFile(in pluginDirectory: URL) -> URL {
        pluginDirectory
            .appendingPathComponent(hooksSubdirName, isDirectory: true)
            .appendingPathComponent(pluginHooksFilename)
            .standardizedFileURL
    }

    public static func pluginMCPFile(in pluginDirectory: URL) -> URL {
        pluginDirectory.appendingPathComponent(projectMCPFilename).standardizedFileURL
    }

    // MARK: - Classification Helpers

    /// Returns `true` when `directory` contains `.git`.
    public static func hasGitMarker(in directory: URL, fileSystem: any ReadOnlyFileSystem) -> Bool {
        fileSystem.exists(directory.appendingPathComponent(gitMarkerName))
    }

    /// Returns `true` when `directory` contains any Claude project-level marker (`.claude`, `.mcp.json`, `CLAUDE.md`, `CLAUDE.local.md`).
    public static func hasClaudeRootMarkers(in directory: URL, fileSystem: any ReadOnlyFileSystem) -> Bool {
        fileSystem.exists(projectDotClaudeDirectory(in: directory))
            || fileSystem.exists(projectMCPFile(in: directory))
            || fileSystem.exists(memoryFile(in: directory))
            || fileSystem.exists(localMemoryFile(in: directory))
    }

    /// Returns `true` when `artifact` originated from the user's cached plugins directory.
    public static func isPluginSourcedArtifact(_ artifact: Artifact, in env: AgentEnvironment) -> Bool {
        let cacheRoot = userPluginsCacheDirectory(in: env)
        let targetURL = URL(fileURLWithPath: artifact.location.path)
        return AdapterPathNormalizer.relativePath(of: targetURL, from: cacheRoot, fileSystem: env.fileSystem) != nil
    }

    /// Returns `true` when `artifact` originated from a project `.mcp.json` file (excluding plugin `.mcp.json`).
    public static func isProjectMCPJsonArtifact(_ artifact: Artifact, in env: AgentEnvironment) -> Bool {
        artifact.kind == .mcpServer
            && artifact.scope == .project
            && URL(fileURLWithPath: artifact.location.path).lastPathComponent == projectMCPFilename
            && !isPluginSourcedArtifact(artifact, in: env)
    }

    /// Returns `true` when `artifact` originated from `<repo>/.claude/settings.local.json`.
    public static func isProjectLocalSettingsArtifact(_ artifact: Artifact) -> Bool {
        artifact.kind == .settings
            && artifact.scope == .projectLocal
            && URL(fileURLWithPath: artifact.location.path).lastPathComponent == settingsLocalFilename
    }

    /// Returns `true` when `artifact` is a modular rule under `.claude/rules/`.
    public static func isModularRulesDirectoryArtifact(_ artifact: Artifact) -> Bool {
        guard artifact.kind == .rules else { return false }
        let components = URL(fileURLWithPath: artifact.location.path).pathComponents
        guard let dotClaudeIdx = components.lastIndex(of: dotClaudeDirName) else { return false }
        return dotClaudeIdx + 1 < components.count && components[dotClaudeIdx + 1] == rulesSubdirName
    }

    /// Human-readable short label for a Claude settings or config file location.
    public static func humanSourceLabel(for path: String, scope: Scope, in env: AgentEnvironment) -> String {
        let filename = URL(fileURLWithPath: path).lastPathComponent
        switch scope {
        case .managed:
            return "managed \(filename)"
        case .projectLocal:
            if filename == settingsLocalFilename {
                return ".claude/\(settingsLocalFilename)"
            }
            if filename == userStateFilename {
                return "~/.claude.json projects entry"
            }
            return "project-local \(filename)"
        case .project:
            if filename == settingsFilename {
                return ".claude/\(settingsFilename)"
            }
            return "project \(filename)"
        case .user:
            if isPathInsidePluginsCache(path, in: env) {
                return "plugin \(filename)"
            }
            if filename == userStateFilename {
                return "user ~/.claude.json"
            }
            return "user ~/.claude/\(filename)"
        case .directory:
            return "directory \(filename)"
        case .builtIn:
            return "built-in"
        }
    }

    private static func isPathInsidePluginsCache(_ path: String, in env: AgentEnvironment) -> Bool {
        let cacheRoot = userPluginsCacheDirectory(in: env)
        return AdapterPathNormalizer.relativePath(
            of: URL(fileURLWithPath: path),
            from: cacheRoot,
            fileSystem: env.fileSystem
        ) != nil
    }
}
