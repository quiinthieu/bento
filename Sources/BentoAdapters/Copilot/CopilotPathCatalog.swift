import BentoCore
import Foundation

/// Single source of truth for all GitHub Copilot CLI filesystem paths, environment overrides,
/// and official documentation provenance (`Docs/adapters/copilot.md`).
public enum CopilotPathCatalog: Sendable {
    /// Environment variable relocating Copilot CLI's user configuration and state directory (`~/.copilot`).
    public static let copilotHomeEnvKey = "COPILOT_HOME"

    private static let verifiedDate = "2026-10-30"
    private static let cliDocURL =
        "https://docs.github.com/en/copilot/how-tos/using-github-copilot-cli"
    private static let instructionsDocURL =
        "https://docs.github.com/en/copilot/customizing-copilot/adding-repository-custom-instructions-for-github-copilot"
    private static let mcpDocURL =
        "https://docs.github.com/en/copilot/customizing-copilot/extending-copilot-chat-with-mcp"
    private static let agentsDocURL =
        "https://docs.github.com/en/copilot/customizing-copilot/creating-custom-agents"
    private static let skillsDocURL =
        "https://docs.github.com/en/copilot/customizing-copilot/using-agent-skills"
    private static let hooksDocURL =
        "https://docs.github.com/en/copilot/customizing-copilot/using-hooks-with-copilot-cli"

    private static let dotCopilotComponent = ".copilot"
    private static let dotGithubComponent = ".github"
    private static let dotVSCodeComponent = ".vscode"
    private static let dotAgentsComponent = ".agents"
    private static let dotGitComponent = ".git"

    /// Canonical `config.json` filename.
    public static let configFileName = "config.json"
    /// Canonical `settings.json` filename.
    public static let settingsFileName = "settings.json"
    /// Canonical `copilot-instructions.md` filename.
    public static let copilotInstructionsFileName = "copilot-instructions.md"
    /// Canonical `mcp-config.json` filename.
    public static let userMCPConfigFileName = "mcp-config.json"
    /// Canonical workspace `mcp.json` filename.
    public static let projectMCPFileName = "mcp.json"
    /// Canonical `AGENTS.md` filename.
    public static let agentsMarkdownFileName = "AGENTS.md"
    /// Canonical `SKILL.md` filename.
    public static let skillMarkdownFileName = "SKILL.md"
    /// Canonical `events.jsonl` session log filename.
    public static let sessionEventsFileName = "events.jsonl"
    /// Canonical compressed `events.jsonl.zst` session log filename.
    public static let compressedSessionEventsFileName = "events.jsonl.zst"
    /// Canonical `workspace.yaml` session metadata filename.
    public static let sessionWorkspaceFileName = "workspace.yaml"

    private static let modularInstructionsSuffix = ".instructions.md"
    private static let customAgentSuffix = ".agent.md"
    private static let promptCommandSuffix = ".prompt.md"

    /// Directories skipped during recursive repository `AGENTS.md` traversal.
    public static let skippedWalkDirectories: Set<String> = [
        dotGitComponent,
        dotGithubComponent,
        dotVSCodeComponent,
        dotAgentsComponent,
        dotCopilotComponent,
        ".claude",
        ".codex",
        ".gemini",
        ".cursor",
        ".windsurf",
        "node_modules",
        ".build",
        "DerivedData",
        "dist",
        "build",
        "target",
        "vendor",
        ".venv",
        "venv"
    ]

    /// Complete `PathCatalog` for `CopilotAdapter`.
    public static let catalog = PathCatalog(entries: [
        PathCatalog.Entry(
            id: "copilot.user.config",
            pattern: "~/.copilot/config.json",
            scope: .user,
            kind: .settings,
            verifiedAt: verifiedDate,
            docURL: cliDocURL
        ),
        PathCatalog.Entry(
            id: "copilot.user.settings",
            pattern: "~/.copilot/settings.json",
            scope: .user,
            kind: .settings,
            verifiedAt: verifiedDate,
            docURL: cliDocURL
        ),
        PathCatalog.Entry(
            id: "copilot.user.instructions",
            pattern: "~/.copilot/copilot-instructions.md",
            scope: .user,
            kind: .rules,
            verifiedAt: verifiedDate,
            docURL: instructionsDocURL
        ),
        PathCatalog.Entry(
            id: "copilot.user.mcp",
            pattern: "~/.copilot/mcp-config.json",
            scope: .user,
            kind: .mcpServer,
            verifiedAt: verifiedDate,
            docURL: mcpDocURL
        ),
        PathCatalog.Entry(
            id: "copilot.user.agentsSkills",
            pattern: "~/.agents/skills/*/SKILL.md",
            scope: .user,
            kind: .skill,
            verifiedAt: verifiedDate,
            docURL: skillsDocURL
        ),
        PathCatalog.Entry(
            id: "copilot.user.copilotSkills",
            pattern: "~/.copilot/skills/*/SKILL.md",
            scope: .user,
            kind: .skill,
            verifiedAt: verifiedDate,
            docURL: skillsDocURL
        ),
        PathCatalog.Entry(
            id: "copilot.user.agents",
            pattern: "~/.copilot/agents/*.agent.md",
            scope: .user,
            kind: .subagent,
            verifiedAt: verifiedDate,
            docURL: agentsDocURL
        ),
        PathCatalog.Entry(
            id: "copilot.user.hooks",
            pattern: "~/.copilot/hooks/*.json",
            scope: .user,
            kind: .hook,
            verifiedAt: verifiedDate,
            docURL: hooksDocURL
        ),
        PathCatalog.Entry(
            id: "copilot.user.sessionLogs",
            pattern: "~/.copilot/session-state/*/events.jsonl",
            scope: .user,
            kind: .settings,
            verifiedAt: verifiedDate,
            docURL: cliDocURL
        ),
        PathCatalog.Entry(
            id: "copilot.project.instructions",
            pattern: "<repo>/.github/copilot-instructions.md",
            scope: .project,
            kind: .rules,
            verifiedAt: verifiedDate,
            docURL: instructionsDocURL
        ),
        PathCatalog.Entry(
            id: "copilot.project.modularInstructions",
            pattern: "<repo>/.github/instructions/**/*.instructions.md",
            scope: .project,
            kind: .rules,
            verifiedAt: verifiedDate,
            docURL: instructionsDocURL
        ),
        PathCatalog.Entry(
            id: "copilot.project.agentsMd",
            pattern: "<repo>/AGENTS.md",
            scope: .project,
            kind: .rules,
            verifiedAt: verifiedDate,
            docURL: instructionsDocURL
        ),
        PathCatalog.Entry(
            id: "copilot.directory.agentsMd",
            pattern: "<subdir>/AGENTS.md",
            scope: .directory,
            kind: .rules,
            verifiedAt: verifiedDate,
            docURL: instructionsDocURL
        ),
        PathCatalog.Entry(
            id: "copilot.project.githubMcp",
            pattern: "<repo>/.github/mcp.json",
            scope: .project,
            kind: .mcpServer,
            verifiedAt: verifiedDate,
            docURL: mcpDocURL
        ),
        PathCatalog.Entry(
            id: "copilot.project.vscodeMcp",
            pattern: "<repo>/.vscode/mcp.json",
            scope: .project,
            kind: .mcpServer,
            verifiedAt: verifiedDate,
            docURL: mcpDocURL
        ),
        PathCatalog.Entry(
            id: "copilot.project.agentsSkills",
            pattern: "<repo>/.agents/skills/*/SKILL.md",
            scope: .project,
            kind: .skill,
            verifiedAt: verifiedDate,
            docURL: skillsDocURL
        ),
        PathCatalog.Entry(
            id: "copilot.project.githubSkills",
            pattern: "<repo>/.github/skills/*/SKILL.md",
            scope: .project,
            kind: .skill,
            verifiedAt: verifiedDate,
            docURL: skillsDocURL
        ),
        PathCatalog.Entry(
            id: "copilot.project.agents",
            pattern: "<repo>/.github/agents/*.agent.md",
            scope: .project,
            kind: .subagent,
            verifiedAt: verifiedDate,
            docURL: agentsDocURL
        ),
        PathCatalog.Entry(
            id: "copilot.project.prompts",
            pattern: "<repo>/.github/prompts/*.prompt.md",
            scope: .project,
            kind: .command,
            verifiedAt: verifiedDate,
            docURL: cliDocURL
        ),
        PathCatalog.Entry(
            id: "copilot.project.hooks",
            pattern: "<repo>/.github/hooks/*.json",
            scope: .project,
            kind: .hook,
            verifiedAt: verifiedDate,
            docURL: hooksDocURL
        )
    ])

    // MARK: - User Paths

    /// Resolves the effective `~/.copilot` directory, honoring `COPILOT_HOME`.
    public static func userCopilotDirectory(in env: AgentEnvironment) -> URL {
        if let override = env.env[copilotHomeEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return AdapterPathNormalizer.expandHomePrefix(override, in: env)
        }
        return env.home.appendingPathComponent(dotCopilotComponent, isDirectory: true).standardizedFileURL
    }

    public static func userConfigFile(in env: AgentEnvironment) -> URL {
        userCopilotDirectory(in: env).appendingPathComponent(configFileName)
    }

    public static func userSettingsFile(in env: AgentEnvironment) -> URL {
        userCopilotDirectory(in: env).appendingPathComponent(settingsFileName)
    }

    public static func userInstructionsFile(in env: AgentEnvironment) -> URL {
        userCopilotDirectory(in: env).appendingPathComponent(copilotInstructionsFileName)
    }

    public static func userMCPConfigFile(in env: AgentEnvironment) -> URL {
        userCopilotDirectory(in: env).appendingPathComponent(userMCPConfigFileName)
    }

    public static func userAgentsSkillsDirectory(in env: AgentEnvironment) -> URL {
        env.home
            .appendingPathComponent(dotAgentsComponent, isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .standardizedFileURL
    }

    public static func userCopilotSkillsDirectory(in env: AgentEnvironment) -> URL {
        userCopilotDirectory(in: env).appendingPathComponent("skills", isDirectory: true)
    }

    public static func userAgentsDirectory(in env: AgentEnvironment) -> URL {
        userCopilotDirectory(in: env).appendingPathComponent("agents", isDirectory: true)
    }

    public static func userHooksDirectory(in env: AgentEnvironment) -> URL {
        userCopilotDirectory(in: env).appendingPathComponent("hooks", isDirectory: true)
    }

    public static func userSessionStateDirectory(in env: AgentEnvironment) -> URL {
        userCopilotDirectory(in: env).appendingPathComponent("session-state", isDirectory: true)
    }

    public static func sessionWorkspaceFile(in sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent(sessionWorkspaceFileName)
    }

    // MARK: - Project & Directory Paths

    public static func projectGithubDirectory(in repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(dotGithubComponent, isDirectory: true).standardizedFileURL
    }

    public static func projectInstructionsFile(in repoRoot: URL) -> URL {
        projectGithubDirectory(in: repoRoot).appendingPathComponent(copilotInstructionsFileName)
    }

    public static func projectModularInstructionsDirectory(in repoRoot: URL) -> URL {
        projectGithubDirectory(in: repoRoot).appendingPathComponent("instructions", isDirectory: true)
    }

    public static func agentsMarkdownFile(in directory: URL) -> URL {
        directory.appendingPathComponent(agentsMarkdownFileName).standardizedFileURL
    }

    public static func projectGithubMCPFile(in repoRoot: URL) -> URL {
        projectGithubDirectory(in: repoRoot).appendingPathComponent(projectMCPFileName)
    }

    public static func projectVSCodeMCPFile(in repoRoot: URL) -> URL {
        repoRoot
            .appendingPathComponent(dotVSCodeComponent, isDirectory: true)
            .appendingPathComponent(projectMCPFileName)
            .standardizedFileURL
    }

    public static func projectAgentsSkillsDirectory(in repoRoot: URL) -> URL {
        repoRoot
            .appendingPathComponent(dotAgentsComponent, isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .standardizedFileURL
    }

    public static func projectGithubSkillsDirectory(in repoRoot: URL) -> URL {
        projectGithubDirectory(in: repoRoot).appendingPathComponent("skills", isDirectory: true)
    }

    public static func projectAgentsDirectory(in repoRoot: URL) -> URL {
        projectGithubDirectory(in: repoRoot).appendingPathComponent("agents", isDirectory: true)
    }

    public static func projectPromptsDirectory(in repoRoot: URL) -> URL {
        projectGithubDirectory(in: repoRoot).appendingPathComponent("prompts", isDirectory: true)
    }

    public static func projectHooksDirectory(in repoRoot: URL) -> URL {
        projectGithubDirectory(in: repoRoot).appendingPathComponent("hooks", isDirectory: true)
    }

    public static func skillMarkdownFile(in skillDirectory: URL) -> URL {
        skillDirectory.appendingPathComponent(skillMarkdownFileName)
    }

    // MARK: - File Classification Helpers

    public static func isModularInstructionFile(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().hasSuffix(modularInstructionsSuffix)
    }

    public static func isCustomAgentFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "md"
    }

    public static func defaultAgentName(for url: URL) -> String {
        let name = url.lastPathComponent
        if name.lowercased().hasSuffix(customAgentSuffix) {
            return String(name.dropLast(customAgentSuffix.count))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    public static func isPromptCommandFile(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().hasSuffix(promptCommandSuffix)
    }

    public static func defaultPromptCommandName(for url: URL) -> String {
        let name = url.lastPathComponent
        if name.lowercased().hasSuffix(promptCommandSuffix) {
            return String(name.dropLast(promptCommandSuffix.count))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    public static func isHookConfigFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "json"
    }

    public static func isSessionEventsLogFile(_ url: URL) -> Bool {
        let lower = url.lastPathComponent.lowercased()
        return lower == sessionEventsFileName || lower == compressedSessionEventsFileName
    }

    public static func isCompressedLogFile(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().hasSuffix(".zst")
    }

    public static func isCrossAgentsSkillsPath(_ path: String) -> Bool {
        path.contains("/\(dotAgentsComponent)/skills/")
    }

    public static func isProjectGithubMCPPath(_ path: String) -> Bool {
        path.hasSuffix("/\(dotGithubComponent)/\(projectMCPFileName)")
    }

    public static func isProjectVSCodeMCPPath(_ path: String) -> Bool {
        path.hasSuffix("/\(dotVSCodeComponent)/\(projectMCPFileName)")
    }

    public static func isRepoCopilotInstructionsPath(_ path: String) -> Bool {
        path.hasSuffix("/\(dotGithubComponent)/\(copilotInstructionsFileName)")
    }

    public static func hasGitMarker(in directory: URL, fileSystem: any ReadOnlyFileSystem) -> Bool {
        fileSystem.exists(directory.appendingPathComponent(dotGitComponent))
    }

    public static func hasCopilotRootMarkers(in directory: URL, fileSystem: any ReadOnlyFileSystem) -> Bool {
        if hasGitMarker(in: directory, fileSystem: fileSystem) {
            return true
        }
        if AdapterPathNormalizer.isEffectiveDirectory(projectGithubDirectory(in: directory), fileSystem: fileSystem) {
            return true
        }
        if AdapterPathNormalizer.isEffectiveFile(projectVSCodeMCPFile(in: directory), fileSystem: fileSystem) {
            return true
        }
        return false
    }
}
