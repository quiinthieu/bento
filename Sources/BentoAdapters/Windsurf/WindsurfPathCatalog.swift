import BentoCore
import Foundation

/// Single source of truth for all Windsurf filesystem paths, character limits, environment overrides,
/// and official documentation provenance (`Docs/adapters/windsurf.md`).
public enum WindsurfPathCatalog: Sendable {
    /// Verified character cap for `~/.codeium/windsurf/memories/global_rules.md` (`PLAN.md` §5.2 & §6.5).
    public static let globalRuleMaxCharacters = 6_000
    /// Verified character cap per workspace or enterprise rule file (`PLAN.md` §5.2 & §6.5).
    public static let workspaceRuleMaxCharacters = 12_000

    /// Optional environment variable relocating `~/.codeium/windsurf` in hermetic tests.
    public static let windsurfConfigDirEnvKey = "WINDSURF_CONFIG_DIR"

    private static let verifiedDate = "2026-10-30"
    private static let memoriesDocURL = "https://docs.windsurf.com/windsurf/cascade/memories"
    private static let mcpDocURL = "https://docs.windsurf.com/windsurf/cascade/mcp"
    private static let workflowsDocURL = "https://docs.windsurf.com/windsurf/cascade/workflows"
    private static let ignoreDocURL = "https://docs.windsurf.com/context-awareness/codeiumignore"

    private static let dotCodeiumComponent = ".codeium"
    private static let windsurfSubdirComponent = "windsurf"
    private static let dotWindsurfComponent = ".windsurf"
    private static let dotGitComponent = ".git"

    /// Canonical `global_rules.md` filename.
    public static let globalRulesFileName = "global_rules.md"
    /// Canonical `mcp_config.json` filename.
    public static let mcpConfigFileName = "mcp_config.json"
    /// Canonical legacy `.windsurfrules` filename.
    public static let legacyWindsurfRulesFileName = ".windsurfrules"
    /// Canonical `AGENTS.md` filename.
    public static let agentsMarkdownFileName = "AGENTS.md"
    /// Canonical `.codeiumignore` filename.
    public static let codeiumIgnoreFileName = ".codeiumignore"

    /// Directories skipped during recursive repository `AGENTS.md` traversal.
    public static let skippedWalkDirectories: Set<String> = [
        dotGitComponent,
        dotWindsurfComponent,
        dotCodeiumComponent,
        ".github",
        ".vscode",
        ".agents",
        ".copilot",
        ".claude",
        ".codex",
        ".gemini",
        ".cursor",
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

    /// Complete `PathCatalog` for `WindsurfAdapter`.
    public static let catalog = PathCatalog(entries: [
        PathCatalog.Entry(
            id: "windsurf.managed.rules",
            pattern: "/Library/Application Support/Windsurf/rules/*.md",
            scope: .managed,
            kind: .rules,
            verifiedAt: verifiedDate,
            docURL: memoriesDocURL
        ),
        PathCatalog.Entry(
            id: "windsurf.user.globalRules",
            pattern: "~/.codeium/windsurf/memories/global_rules.md",
            scope: .user,
            kind: .rules,
            verifiedAt: verifiedDate,
            docURL: memoriesDocURL
        ),
        PathCatalog.Entry(
            id: "windsurf.user.mcp",
            pattern: "~/.codeium/windsurf/mcp_config.json",
            scope: .user,
            kind: .mcpServer,
            verifiedAt: verifiedDate,
            docURL: mcpDocURL
        ),
        PathCatalog.Entry(
            id: "windsurf.user.workflows",
            pattern: "~/.codeium/windsurf/global_workflows/*.md",
            scope: .user,
            kind: .command,
            verifiedAt: verifiedDate,
            docURL: workflowsDocURL
        ),
        PathCatalog.Entry(
            id: "windsurf.project.rules",
            pattern: "<repo>/.windsurf/rules/**/*.md",
            scope: .project,
            kind: .rules,
            verifiedAt: verifiedDate,
            docURL: memoriesDocURL
        ),
        PathCatalog.Entry(
            id: "windsurf.project.legacyRules",
            pattern: "<repo>/.windsurfrules",
            scope: .project,
            kind: .rules,
            verifiedAt: verifiedDate,
            docURL: memoriesDocURL
        ),
        PathCatalog.Entry(
            id: "windsurf.project.agentsMd",
            pattern: "<repo>/AGENTS.md",
            scope: .project,
            kind: .rules,
            verifiedAt: verifiedDate,
            docURL: memoriesDocURL
        ),
        PathCatalog.Entry(
            id: "windsurf.directory.agentsMd",
            pattern: "<subdir>/AGENTS.md",
            scope: .directory,
            kind: .rules,
            verifiedAt: verifiedDate,
            docURL: memoriesDocURL
        ),
        PathCatalog.Entry(
            id: "windsurf.project.workflows",
            pattern: "<repo>/.windsurf/workflows/*.md",
            scope: .project,
            kind: .command,
            verifiedAt: verifiedDate,
            docURL: workflowsDocURL
        ),
        PathCatalog.Entry(
            id: "windsurf.project.ignore",
            pattern: "<repo>/.codeiumignore",
            scope: .project,
            kind: .ignoreFile,
            verifiedAt: verifiedDate,
            docURL: ignoreDocURL
        )
    ])

    // MARK: - Managed & User Paths

    public static func managedRulesDirectory(in env: AgentEnvironment) -> URL {
        AdapterPathNormalizer.systemRootURL(in: env)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Windsurf", isDirectory: true)
            .appendingPathComponent("rules", isDirectory: true)
            .standardizedFileURL
    }

    public static func userWindsurfDirectory(in env: AgentEnvironment) -> URL {
        if let override = env.env[windsurfConfigDirEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return AdapterPathNormalizer.expandHomePrefix(override, in: env)
        }
        return env.home
            .appendingPathComponent(dotCodeiumComponent, isDirectory: true)
            .appendingPathComponent(windsurfSubdirComponent, isDirectory: true)
            .standardizedFileURL
    }

    public static func userGlobalRulesFile(in env: AgentEnvironment) -> URL {
        userWindsurfDirectory(in: env)
            .appendingPathComponent("memories", isDirectory: true)
            .appendingPathComponent(globalRulesFileName)
            .standardizedFileURL
    }

    public static func userMCPConfigFile(in env: AgentEnvironment) -> URL {
        userWindsurfDirectory(in: env).appendingPathComponent(mcpConfigFileName)
    }

    public static func userGlobalWorkflowsDirectory(in env: AgentEnvironment) -> URL {
        userWindsurfDirectory(in: env).appendingPathComponent("global_workflows", isDirectory: true)
    }

    // MARK: - Project & Directory Paths

    public static func dotWindsurfDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent(dotWindsurfComponent, isDirectory: true).standardizedFileURL
    }

    public static func projectRulesDirectory(in repoRoot: URL) -> URL {
        dotWindsurfDirectory(in: repoRoot).appendingPathComponent("rules", isDirectory: true)
    }

    public static func projectWorkflowsDirectory(in repoRoot: URL) -> URL {
        dotWindsurfDirectory(in: repoRoot).appendingPathComponent("workflows", isDirectory: true)
    }

    public static func legacyWindsurfRulesFile(in repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(legacyWindsurfRulesFileName).standardizedFileURL
    }

    public static func agentsMarkdownFile(in directory: URL) -> URL {
        directory.appendingPathComponent(agentsMarkdownFileName).standardizedFileURL
    }

    public static func projectIgnoreFile(in repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(codeiumIgnoreFileName).standardizedFileURL
    }

    // MARK: - Classification Helpers

    public static func isMarkdownFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "md"
    }

    public static func isLegacyWindsurfRulesPath(_ path: String) -> Bool {
        path.hasSuffix("/\(legacyWindsurfRulesFileName)")
    }

    public static func isWorkspaceRulesDirectoryPath(_ path: String) -> Bool {
        path.contains("/\(dotWindsurfComponent)/rules/")
    }

    public static func hasGitMarker(in directory: URL, fileSystem: any ReadOnlyFileSystem) -> Bool {
        fileSystem.exists(directory.appendingPathComponent(dotGitComponent))
    }

    public static func hasWindsurfRootMarkers(in directory: URL, fileSystem: any ReadOnlyFileSystem) -> Bool {
        if hasGitMarker(in: directory, fileSystem: fileSystem) {
            return true
        }
        if AdapterPathNormalizer.isEffectiveDirectory(dotWindsurfDirectory(in: directory), fileSystem: fileSystem) {
            return true
        }
        if AdapterPathNormalizer.isEffectiveFile(legacyWindsurfRulesFile(in: directory), fileSystem: fileSystem) {
            return true
        }
        return false
    }
}
