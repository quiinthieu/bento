import BentoCore
import Foundation

/// Single source of truth for all OpenAI Codex CLI configuration, rules, skill, hook, and log paths,
/// verified against official documentation and `codex-cli 0.165.0` (`Docs/adapters/codex.md`).
public enum CodexPathCatalog: Sendable {
    /// ISO-8601 verification date for all catalog entries.
    public static let verifiedDate = "2026-10-30"

    /// Environment variable overriding the user `.codex` directory.
    public static let codexHomeEnvKey = "CODEX_HOME"
    /// Environment variable overriding the active `[profiles.<name>]` selection.
    public static let codexProfileEnvKey = "CODEX_PROFILE"

    /// Default cumulative UTF-8 byte cap for Codex project instructions (`32 KiB`).
    public static let defaultProjectDocMaxBytes = 32_768

    private static let configBasicDocURL = "https://developers.openai.com/codex/config-basic"
    private static let configAdvancedDocURL = "https://developers.openai.com/codex/config-advanced"
    private static let agentsDocURL = "https://developers.openai.com/codex/guides/agents-md"
    private static let mcpDocURL = "https://developers.openai.com/codex/mcp"
    private static let skillsDocURL = "https://developers.openai.com/codex/skills"
    private static let securityDocURL = "https://developers.openai.com/codex/security"

    // MARK: - Path Components

    private static let managedRelativeDirectory = "etc/codex"
    private static let dotCodexDirName = ".codex"
    private static let dotAgentsDirName = ".agents"
    private static let configFilename = "config.toml"
    private static let requirementsFilename = "requirements.toml"
    private static let hooksFilename = "hooks.json"

    /// Canonical Markdown filename for Codex instructions.
    public static let rulesFilename = "AGENTS.md"
    /// Canonical Markdown filename for Codex escape-hatch override instructions.
    public static let rulesOverrideFilename = "AGENTS.override.md"
    /// Canonical Markdown filename for skill manifests.
    public static let skillManifestFilename = "SKILL.md"

    private static let skillsSubdirName = "skills"
    private static let systemSkillsSubdirName = ".system"
    private static let sessionsLogsSubdirName = "sessions"
    private static let gitMarkerName = ".git"

    /// Directory names skipped when scanning descendant project directories for nested rules.
    public static let skippedDescendantDirectoryNames: Set<String> = [
        gitMarkerName,
        dotCodexDirName,
        dotAgentsDirName,
        ".claude",
        ".gemini",
        ".cursor",
        ".windsurf",
        ".github",
        ".build",
        ".swiftpm",
        "node_modules",
        "DerivedData"
    ]

    /// Complete declarative `PathCatalog` for OpenAI Codex CLI.
    public static let catalog = PathCatalog(
        entries: [
            PathCatalog.Entry(
                id: "codex.managed.config",
                pattern: "/etc/codex/config.toml",
                scope: .managed,
                kind: .settings,
                verifiedAt: verifiedDate,
                docURL: configAdvancedDocURL
            ),
            PathCatalog.Entry(
                id: "codex.managed.requirements",
                pattern: "/etc/codex/requirements.toml",
                scope: .managed,
                kind: .settings,
                verifiedAt: verifiedDate,
                docURL: securityDocURL
            ),
            PathCatalog.Entry(
                id: "codex.managed.hooks",
                pattern: "/etc/codex/hooks.json",
                scope: .managed,
                kind: .hook,
                verifiedAt: verifiedDate,
                docURL: securityDocURL
            ),
            PathCatalog.Entry(
                id: "codex.user.config",
                pattern: "~/.codex/config.toml",
                scope: .user,
                kind: .settings,
                verifiedAt: verifiedDate,
                docURL: configBasicDocURL
            ),
            PathCatalog.Entry(
                id: "codex.user.rulesOverride",
                pattern: "~/.codex/AGENTS.override.md",
                scope: .user,
                kind: .rules,
                verifiedAt: verifiedDate,
                docURL: agentsDocURL
            ),
            PathCatalog.Entry(
                id: "codex.user.rules",
                pattern: "~/.codex/AGENTS.md",
                scope: .user,
                kind: .rules,
                verifiedAt: verifiedDate,
                docURL: agentsDocURL
            ),
            PathCatalog.Entry(
                id: "codex.user.agentsSkills",
                pattern: "~/.agents/skills/*/SKILL.md",
                scope: .user,
                kind: .skill,
                verifiedAt: verifiedDate,
                docURL: skillsDocURL
            ),
            PathCatalog.Entry(
                id: "codex.user.codexSkills",
                pattern: "~/.codex/skills/*/SKILL.md",
                scope: .user,
                kind: .skill,
                verifiedAt: verifiedDate,
                docURL: skillsDocURL
            ),
            PathCatalog.Entry(
                id: "codex.builtin.systemSkills",
                pattern: "~/.codex/skills/.system/*/SKILL.md",
                scope: .builtIn,
                kind: .skill,
                verifiedAt: verifiedDate,
                docURL: skillsDocURL
            ),
            PathCatalog.Entry(
                id: "codex.user.hooks",
                pattern: "~/.codex/hooks.json",
                scope: .user,
                kind: .hook,
                verifiedAt: verifiedDate,
                docURL: securityDocURL
            ),
            PathCatalog.Entry(
                id: "codex.user.logs",
                pattern: "~/.codex/sessions/**/*.jsonl",
                scope: .user,
                kind: .settings,
                verifiedAt: verifiedDate,
                docURL: configBasicDocURL
            ),
            PathCatalog.Entry(
                id: "codex.project.config",
                pattern: "<repo>/.codex/config.toml",
                scope: .project,
                kind: .settings,
                verifiedAt: verifiedDate,
                docURL: mcpDocURL
            ),
            PathCatalog.Entry(
                id: "codex.directory.config",
                pattern: "<subdir>/.codex/config.toml",
                scope: .directory,
                kind: .settings,
                verifiedAt: verifiedDate,
                docURL: configAdvancedDocURL
            ),
            PathCatalog.Entry(
                id: "codex.project.rulesOverride",
                pattern: "<repo>/AGENTS.override.md",
                scope: .project,
                kind: .rules,
                verifiedAt: verifiedDate,
                docURL: agentsDocURL
            ),
            PathCatalog.Entry(
                id: "codex.project.rules",
                pattern: "<repo>/AGENTS.md",
                scope: .project,
                kind: .rules,
                verifiedAt: verifiedDate,
                docURL: agentsDocURL
            ),
            PathCatalog.Entry(
                id: "codex.directory.rules",
                pattern: "<subdir>/AGENTS.md",
                scope: .directory,
                kind: .rules,
                verifiedAt: verifiedDate,
                docURL: agentsDocURL
            ),
            PathCatalog.Entry(
                id: "codex.project.agentsSkills",
                pattern: "<repo>/.agents/skills/*/SKILL.md",
                scope: .project,
                kind: .skill,
                verifiedAt: verifiedDate,
                docURL: skillsDocURL
            ),
            PathCatalog.Entry(
                id: "codex.project.codexSkills",
                pattern: "<repo>/.codex/skills/*/SKILL.md",
                scope: .project,
                kind: .skill,
                verifiedAt: verifiedDate,
                docURL: skillsDocURL
            ),
            PathCatalog.Entry(
                id: "codex.project.hooks",
                pattern: "<repo>/.codex/hooks.json",
                scope: .project,
                kind: .hook,
                verifiedAt: verifiedDate,
                docURL: securityDocURL
            )
        ]
    )

    // MARK: - Managed Paths

    /// System-managed Codex directory (`/etc/codex` under `BENTO_SYSTEM_ROOT` or `/`).
    public static func managedDirectory(in env: AgentEnvironment) -> URL {
        AdapterPathNormalizer.systemRootURL(in: env)
            .appendingPathComponent(managedRelativeDirectory, isDirectory: true)
            .standardizedFileURL
    }

    /// System-managed `/etc/codex/config.toml`.
    public static func managedConfigFile(in env: AgentEnvironment) -> URL {
        managedDirectory(in: env).appendingPathComponent(configFilename)
    }

    /// System-managed `/etc/codex/requirements.toml`.
    public static func managedRequirementsFile(in env: AgentEnvironment) -> URL {
        managedDirectory(in: env).appendingPathComponent(requirementsFilename)
    }

    /// System-managed `/etc/codex/hooks.json`.
    public static func managedHooksFile(in env: AgentEnvironment) -> URL {
        managedDirectory(in: env).appendingPathComponent(hooksFilename)
    }

    // MARK: - User Paths

    /// Effective `$CODEX_HOME` directory (`env["CODEX_HOME"]` when set, otherwise `<home>/.codex`).
    public static func userCodexDirectory(in env: AgentEnvironment) -> URL {
        if let raw = env.env[codexHomeEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        {
            return AdapterPathNormalizer.expandHomePrefix(raw, in: env)
        }
        return env.home.appendingPathComponent(dotCodexDirName, isDirectory: true).standardizedFileURL
    }

    /// User `config.toml` inside `$CODEX_HOME`.
    public static func userConfigFile(in env: AgentEnvironment) -> URL {
        userCodexDirectory(in: env).appendingPathComponent(configFilename)
    }

    /// User `AGENTS.override.md` inside `$CODEX_HOME`.
    public static func userRulesOverrideFile(in env: AgentEnvironment) -> URL {
        userCodexDirectory(in: env).appendingPathComponent(rulesOverrideFilename)
    }

    /// User `AGENTS.md` inside `$CODEX_HOME`.
    public static func userRulesFile(in env: AgentEnvironment) -> URL {
        userCodexDirectory(in: env).appendingPathComponent(rulesFilename)
    }

    /// User `hooks.json` inside `$CODEX_HOME`.
    public static func userHooksFile(in env: AgentEnvironment) -> URL {
        userCodexDirectory(in: env).appendingPathComponent(hooksFilename)
    }

    /// Cross-agent user skills directory `<home>/.agents/skills`.
    public static func userAgentsSkillsDirectory(in env: AgentEnvironment) -> URL {
        env.home
            .appendingPathComponent(dotAgentsDirName, isDirectory: true)
            .appendingPathComponent(skillsSubdirName, isDirectory: true)
            .standardizedFileURL
    }

    /// Codex user skills directory `<CODEX_HOME>/skills`.
    public static func userCodexSkillsDirectory(in env: AgentEnvironment) -> URL {
        userCodexDirectory(in: env)
            .appendingPathComponent(skillsSubdirName, isDirectory: true)
            .standardizedFileURL
    }

    /// Bundled system skills directory `<CODEX_HOME>/skills/.system`.
    public static func builtInSystemSkillsDirectory(in env: AgentEnvironment) -> URL {
        userCodexSkillsDirectory(in: env)
            .appendingPathComponent(systemSkillsSubdirName, isDirectory: true)
            .standardizedFileURL
    }

    /// User session logs directory `<CODEX_HOME>/sessions`.
    public static func userLogsDirectory(in env: AgentEnvironment) -> URL {
        userCodexDirectory(in: env)
            .appendingPathComponent(sessionsLogsSubdirName, isDirectory: true)
            .standardizedFileURL
    }

    // MARK: - Project & Directory Paths

    /// `<dir>/.codex/config.toml`.
    public static func directoryConfigFile(in directory: URL) -> URL {
        directory
            .appendingPathComponent(dotCodexDirName, isDirectory: true)
            .appendingPathComponent(configFilename)
            .standardizedFileURL
    }

    /// `<dir>/.codex/hooks.json`.
    public static func directoryHooksFile(in directory: URL) -> URL {
        directory
            .appendingPathComponent(dotCodexDirName, isDirectory: true)
            .appendingPathComponent(hooksFilename)
            .standardizedFileURL
    }

    /// `<dir>/.agents/skills`.
    public static func directoryAgentsSkillsDirectory(in directory: URL) -> URL {
        directory
            .appendingPathComponent(dotAgentsDirName, isDirectory: true)
            .appendingPathComponent(skillsSubdirName, isDirectory: true)
            .standardizedFileURL
    }

    /// `<dir>/.codex/skills`.
    public static func directoryCodexSkillsDirectory(in directory: URL) -> URL {
        directory
            .appendingPathComponent(dotCodexDirName, isDirectory: true)
            .appendingPathComponent(skillsSubdirName, isDirectory: true)
            .standardizedFileURL
    }

    /// Ordered candidate instruction filenames for any project/nested directory:
    /// `AGENTS.override.md` -> `AGENTS.md` -> `fallbackFilenames` (deduplicated).
    public static func orderedRuleCandidateFilenames(fallbackFilenames: [String]) -> [String] {
        var result = [rulesOverrideFilename, rulesFilename]
        for fallback in fallbackFilenames {
            let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("/"), !result.contains(trimmed) else {
                continue
            }
            result.append(trimmed)
        }
        return result
    }

    // MARK: - Classification Helpers

    /// Returns `true` when `directory` contains a `.git` file or folder.
    public static func hasGitMarker(in directory: URL, fileSystem: any ReadOnlyFileSystem) -> Bool {
        fileSystem.exists(directory.appendingPathComponent(gitMarkerName))
    }

    /// Returns `true` when `directory` contains Codex root markers (`.codex/`, `.agents/`, `AGENTS.override.md`, or `AGENTS.md`).
    public static func hasCodexRootMarkers(in directory: URL, fileSystem: any ReadOnlyFileSystem) -> Bool {
        let markers = [
            directory.appendingPathComponent(dotCodexDirName),
            directory.appendingPathComponent(dotAgentsDirName),
            directory.appendingPathComponent(rulesOverrideFilename),
            directory.appendingPathComponent(rulesFilename)
        ]
        return markers.contains { fileSystem.exists($0) }
    }

    /// Returns `true` if `name` is the `.system` built-in skill container directory.
    public static func isSystemSkillsSubdirectoryName(_ name: String) -> Bool {
        name == systemSkillsSubdirName
    }

    /// Returns `true` when `path` resides under an `.agents/skills/` tree (higher tie-break priority than `.codex/skills/`).
    public static func isAgentsAliasSkillPath(_ path: String) -> Bool {
        path.contains("/\(dotAgentsDirName)/\(skillsSubdirName)/")
    }

    /// Returns `true` when `path` is `requirements.toml` (higher managed precedence than `config.toml`).
    public static func isManagedRequirementsPath(_ path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent == requirementsFilename
    }

    /// Human-readable source label for `Resolution` and `ShadowRecord` explanations.
    public static func humanSourceLabel(for path: String, scope: Scope, in env: AgentEnvironment) -> String {
        let filename = URL(fileURLWithPath: path).lastPathComponent
        switch scope {
        case .managed:
            return "/\(managedRelativeDirectory)/\(filename)"
        case .user:
            if isAgentsAliasSkillPath(path) {
                return "~/\(dotAgentsDirName)/\(skillsSubdirName)"
            }
            let codexDir = userCodexDirectory(in: env).path
            if path.hasPrefix(codexDir + "/") {
                let rel = String(path.dropFirst(codexDir.count + 1))
                return "~/\(dotCodexDirName)/\(rel)"
            }
            return "~/\(dotCodexDirName)/\(filename)"
        case .builtIn:
            return "~/\(dotCodexDirName)/\(skillsSubdirName)/\(systemSkillsSubdirName)"
        case .project:
            if isAgentsAliasSkillPath(path) {
                return "project \(dotAgentsDirName)/\(skillsSubdirName)"
            }
            if path.contains("/\(dotCodexDirName)/") {
                return "project \(dotCodexDirName)/\(filename)"
            }
            return "project \(filename)"
        case .directory:
            if path.contains("/\(dotCodexDirName)/") {
                return "directory \(dotCodexDirName)/\(filename)"
            }
            return "directory \(filename)"
        case .projectLocal:
            return "local \(filename)"
        }
    }
}
