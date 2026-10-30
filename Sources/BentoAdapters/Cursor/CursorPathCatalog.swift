import BentoCore
import Foundation

/// Single source of truth for all Cursor filesystem paths, environment overrides,
/// and official documentation provenance (`Docs/adapters/cursor.md`).
public enum CursorPathCatalog: Sendable {
    /// Optional environment variable relocating `~/.cursor` in hermetic tests.
    public static let cursorConfigDirEnvKey = "CURSOR_CONFIG_DIR"

    private static let verifiedDate = "2026-10-30"
    private static let rulesDocURL = "https://cursor.com/docs/context/rules"
    private static let mcpDocURL = "https://cursor.com/docs/context/mcp"
    private static let ignoreDocURL = "https://cursor.com/docs/context/ignore-files"
    private static let subagentsDocURL = "https://cursor.com/docs/context/subagents"

    private static let dotCursorComponent = ".cursor"
    private static let dotGitComponent = ".git"

    /// Canonical `mcp.json` filename.
    public static let mcpFileName = "mcp.json"
    /// Canonical legacy `.cursorrules` filename.
    public static let legacyCursorRulesFileName = ".cursorrules"
    /// Canonical `AGENTS.md` filename.
    public static let agentsMarkdownFileName = "AGENTS.md"
    /// Canonical `SKILL.md` filename.
    public static let skillMarkdownFileName = "SKILL.md"
    /// Canonical `.cursorignore` filename.
    public static let cursorIgnoreFileName = ".cursorignore"
    /// Canonical `.cursorindexingignore` filename.
    public static let cursorIndexingIgnoreFileName = ".cursorindexingignore"

    /// Directories skipped during recursive repository traversal.
    public static let skippedWalkDirectories: Set<String> = [
        dotGitComponent,
        dotCursorComponent,
        ".github",
        ".vscode",
        ".agents",
        ".copilot",
        ".claude",
        ".codex",
        ".gemini",
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

    /// Complete `PathCatalog` for `CursorAdapter`.
    public static let catalog = PathCatalog(entries: [
        PathCatalog.Entry(
            id: "cursor.user.mcp",
            pattern: "~/.cursor/mcp.json",
            scope: .user,
            kind: .mcpServer,
            verifiedAt: verifiedDate,
            docURL: mcpDocURL
        ),
        PathCatalog.Entry(
            id: "cursor.user.skills",
            pattern: "~/.cursor/skills/*/SKILL.md",
            scope: .user,
            kind: .skill,
            verifiedAt: verifiedDate,
            docURL: subagentsDocURL
        ),
        PathCatalog.Entry(
            id: "cursor.user.agents",
            pattern: "~/.cursor/agents/*.md",
            scope: .user,
            kind: .subagent,
            verifiedAt: verifiedDate,
            docURL: subagentsDocURL
        ),
        PathCatalog.Entry(
            id: "cursor.project.rules",
            pattern: "<repo>/.cursor/rules/**/*.mdc",
            scope: .project,
            kind: .rules,
            verifiedAt: verifiedDate,
            docURL: rulesDocURL
        ),
        PathCatalog.Entry(
            id: "cursor.directory.rules",
            pattern: "<subdir>/.cursor/rules/**/*.mdc",
            scope: .directory,
            kind: .rules,
            verifiedAt: verifiedDate,
            docURL: rulesDocURL
        ),
        PathCatalog.Entry(
            id: "cursor.project.legacyRules",
            pattern: "<repo>/.cursorrules",
            scope: .project,
            kind: .rules,
            verifiedAt: verifiedDate,
            docURL: rulesDocURL
        ),
        PathCatalog.Entry(
            id: "cursor.project.agentsMd",
            pattern: "<repo>/AGENTS.md",
            scope: .project,
            kind: .rules,
            verifiedAt: verifiedDate,
            docURL: rulesDocURL
        ),
        PathCatalog.Entry(
            id: "cursor.directory.agentsMd",
            pattern: "<subdir>/AGENTS.md",
            scope: .directory,
            kind: .rules,
            verifiedAt: verifiedDate,
            docURL: rulesDocURL
        ),
        PathCatalog.Entry(
            id: "cursor.project.mcp",
            pattern: "<repo>/.cursor/mcp.json",
            scope: .project,
            kind: .mcpServer,
            verifiedAt: verifiedDate,
            docURL: mcpDocURL
        ),
        PathCatalog.Entry(
            id: "cursor.project.skills",
            pattern: "<repo>/.cursor/skills/*/SKILL.md",
            scope: .project,
            kind: .skill,
            verifiedAt: verifiedDate,
            docURL: subagentsDocURL
        ),
        PathCatalog.Entry(
            id: "cursor.project.agents",
            pattern: "<repo>/.cursor/agents/*.md",
            scope: .project,
            kind: .subagent,
            verifiedAt: verifiedDate,
            docURL: subagentsDocURL
        ),
        PathCatalog.Entry(
            id: "cursor.project.ignore",
            pattern: "<repo>/.cursorignore",
            scope: .project,
            kind: .ignoreFile,
            verifiedAt: verifiedDate,
            docURL: ignoreDocURL
        ),
        PathCatalog.Entry(
            id: "cursor.project.indexingIgnore",
            pattern: "<repo>/.cursorindexingignore",
            scope: .project,
            kind: .ignoreFile,
            verifiedAt: verifiedDate,
            docURL: ignoreDocURL
        )
    ])

    // MARK: - User Paths

    public static func userCursorDirectory(in env: AgentEnvironment) -> URL {
        if let override = env.env[cursorConfigDirEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return AdapterPathNormalizer.expandHomePrefix(override, in: env)
        }
        return env.home.appendingPathComponent(dotCursorComponent, isDirectory: true).standardizedFileURL
    }

    public static func userMCPFile(in env: AgentEnvironment) -> URL {
        userCursorDirectory(in: env).appendingPathComponent(mcpFileName)
    }

    public static func userSkillsDirectory(in env: AgentEnvironment) -> URL {
        userCursorDirectory(in: env).appendingPathComponent("skills", isDirectory: true)
    }

    public static func userAgentsDirectory(in env: AgentEnvironment) -> URL {
        userCursorDirectory(in: env).appendingPathComponent("agents", isDirectory: true)
    }

    // MARK: - Project & Directory Paths

    public static func dotCursorDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent(dotCursorComponent, isDirectory: true).standardizedFileURL
    }

    public static func rulesDirectory(in directory: URL) -> URL {
        dotCursorDirectory(in: directory).appendingPathComponent("rules", isDirectory: true)
    }

    public static func projectMCPFile(in repoRoot: URL) -> URL {
        dotCursorDirectory(in: repoRoot).appendingPathComponent(mcpFileName)
    }

    public static func projectSkillsDirectory(in repoRoot: URL) -> URL {
        dotCursorDirectory(in: repoRoot).appendingPathComponent("skills", isDirectory: true)
    }

    public static func projectAgentsDirectory(in repoRoot: URL) -> URL {
        dotCursorDirectory(in: repoRoot).appendingPathComponent("agents", isDirectory: true)
    }

    public static func legacyCursorRulesFile(in repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(legacyCursorRulesFileName).standardizedFileURL
    }

    public static func agentsMarkdownFile(in directory: URL) -> URL {
        directory.appendingPathComponent(agentsMarkdownFileName).standardizedFileURL
    }

    public static func projectIgnoreFile(in repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(cursorIgnoreFileName).standardizedFileURL
    }

    public static func projectIndexingIgnoreFile(in repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(cursorIndexingIgnoreFileName).standardizedFileURL
    }

    public static func skillMarkdownFile(in skillDirectory: URL) -> URL {
        skillDirectory.appendingPathComponent(skillMarkdownFileName)
    }

    // MARK: - File Classification Helpers

    public static func isCursorRuleFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "mdc" || ext == "md"
    }

    public static func isSubagentFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "md"
    }

    public static func isLegacyCursorRulesPath(_ path: String) -> Bool {
        path.hasSuffix("/\(legacyCursorRulesFileName)")
    }

    public static func isCursorRulesDirectoryPath(_ path: String) -> Bool {
        path.contains("/\(dotCursorComponent)/rules/")
    }

    public static func cursorRulesOwnerDirectory(for ruleFileURL: URL) -> URL {
        let components = ruleFileURL.standardizedFileURL.pathComponents
        if let idx = components.lastIndex(of: dotCursorComponent), idx > 0 {
            let prefix = components[0..<idx].joined(separator: "/")
            return URL(fileURLWithPath: prefix.isEmpty ? "/" : prefix, isDirectory: true).standardizedFileURL
        }
        return ruleFileURL.deletingLastPathComponent().standardizedFileURL
    }

    public static func hasGitMarker(in directory: URL, fileSystem: any ReadOnlyFileSystem) -> Bool {
        fileSystem.exists(directory.appendingPathComponent(dotGitComponent))
    }

    public static func hasCursorRootMarkers(in directory: URL, fileSystem: any ReadOnlyFileSystem) -> Bool {
        if hasGitMarker(in: directory, fileSystem: fileSystem) {
            return true
        }
        if AdapterPathNormalizer.isEffectiveDirectory(dotCursorDirectory(in: directory), fileSystem: fileSystem) {
            return true
        }
        if AdapterPathNormalizer.isEffectiveFile(legacyCursorRulesFile(in: directory), fileSystem: fileSystem) {
            return true
        }
        return false
    }
}
