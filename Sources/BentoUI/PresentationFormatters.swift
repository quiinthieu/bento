import BentoCore
import BentoFixes
import SwiftUI

extension AgentID {
    public var displayName: String {
        switch self {
        case .claudeCode:
            return "Claude Code"
        case .codex:
            return "Codex CLI"
        case .gemini:
            return "Gemini CLI"
        case .copilot:
            return "Copilot CLI"
        case .cursor:
            return "Cursor"
        case .windsurf:
            return "Windsurf"
        }
    }

    public var shortDisplayName: String {
        switch self {
        case .claudeCode:
            return "Claude"
        case .codex:
            return "Codex"
        case .gemini:
            return "Gemini"
        case .copilot:
            return "Copilot"
        case .cursor:
            return "Cursor"
        case .windsurf:
            return "Windsurf"
        }
    }

    public var supportsFullBudgetAndUsage: Bool {
        switch self {
        case .claudeCode, .codex, .gemini, .copilot:
            return true
        case .cursor, .windsurf:
            return false
        }
    }

    public var symbolName: String {
        switch self {
        case .claudeCode:
            return "sparkles.rectangle.stack"
        case .codex:
            return "terminal"
        case .gemini:
            return "diamond"
        case .copilot:
            return "airplane"
        case .cursor:
            return "cursorarrow.rays"
        case .windsurf:
            return "wind"
        }
    }
}

extension BudgetCategory {
    public var displayName: String {
        switch self {
        case .builtInSystem:
            return "Built-in System"
        case .builtInTools:
            return "Built-in Tools"
        case .rules:
            return "Rules"
        case .skillFrontmatter:
            return "Skill Frontmatter"
        case .skillBody:
            return "Skill Body"
        case .mcpToolsLoaded:
            return "MCP Tools (Loaded)"
        case .mcpToolsDeferred:
            return "MCP Tools (Deferred)"
        case .subagents:
            return "Subagents"
        case .commands:
            return "Commands"
        case .hooks:
            return "Hooks"
        case .other:
            return "Other"
        }
    }

    public var chartColor: Color {
        switch self {
        case .builtInSystem:
            return .gray
        case .builtInTools:
            return Color(red: 0.45, green: 0.52, blue: 0.62)
        case .rules:
            return .blue
        case .skillFrontmatter:
            return .teal
        case .skillBody:
            return .mint
        case .mcpToolsLoaded:
            return .orange
        case .mcpToolsDeferred:
            return .purple
        case .subagents:
            return .indigo
        case .commands:
            return .cyan
        case .hooks:
            return .pink
        case .other:
            return .secondary
        }
    }
}

extension Confidence {
    public var badgeTitle: String {
        switch self {
        case .exact:
            return "Exact"
        case .estimated:
            return "Est."
        case .measured:
            return "Measured"
        }
    }

    public var badgeColor: Color {
        switch self {
        case .exact:
            return .green
        case .estimated:
            return .orange
        case .measured:
            return .blue
        }
    }
}

extension Scope {
    public var badgeTitle: String {
        switch self {
        case .managed:
            return "Managed"
        case .projectLocal:
            return "Local"
        case .project:
            return "Project"
        case .directory:
            return "Directory"
        case .user:
            return "User"
        case .builtIn:
            return "Built-in"
        }
    }

    public var badgeColor: Color {
        switch self {
        case .managed:
            return .purple
        case .projectLocal:
            return .teal
        case .project:
            return .blue
        case .directory:
            return .indigo
        case .user:
            return .orange
        case .builtIn:
            return .gray
        }
    }
}

extension ArtifactKind {
    public var displayName: String {
        switch self {
        case .settings:
            return "Settings"
        case .rules:
            return "Rules"
        case .skill:
            return "Skill"
        case .mcpServer:
            return "MCP Server"
        case .subagent:
            return "Subagent"
        case .command:
            return "Command"
        case .hook:
            return "Hook"
        case .plugin:
            return "Plugin"
        case .outputStyle:
            return "Output Style"
        case .ignoreFile:
            return "Ignore File"
        }
    }
}

extension LoadMode {
    public var displayLabel: String {
        switch self {
        case .always:
            return "Always loaded"
        case .frontmatterOnly:
            return "Frontmatter upfront"
        case .deferred:
            return "Deferred (tool search)"
        case .onInvoke:
            return "On invoke"
        case .conditional(let globs):
            if globs.isEmpty {
                return "Conditional"
            }
            return "Conditional (\(globs.joined(separator: ", ")))"
        case .never:
            return "Disabled"
        }
    }
}

extension Finding.Kind {
    public var displayName: String {
        switch self {
        case .nearDuplicate:
            return "Near Duplicate"
        case .exactDuplicate:
            return "Exact Duplicate"
        case .conflict:
            return "Conflicting Rules"
        case .sizeLimit:
            return "Size Limit"
        case .unused:
            return "Unused Artifact"
        case .brokenImport:
            return "Broken Import"
        case .shadowed:
            return "Shadowed Config"
        case .invalidConfig:
            return "Invalid Config"
        }
    }
}

extension Severity {
    public var symbolName: String {
        switch self {
        case .error:
            return "xmark.octagon.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .info:
            return "info.circle.fill"
        }
    }

    public var tintColor: Color {
        switch self {
        case .error:
            return .red
        case .warning:
            return .orange
        case .info:
            return .blue
        }
    }
}

extension FixKind {
    public var displayName: String {
        switch self {
        case .disableMCPServer:
            return "Disable MCP Server"
        case .enableMCPServer:
            return "Enable MCP Server"
        case .disableSkill:
            return "Disable Skill"
        case .enableSkill:
            return "Enable Skill"
        case .consolidateSkillsViaSymlink:
            return "Consolidate Identical Skills via Symlink"
        case .replaceDuplicateRulesWithImport:
            return "Replace Duplicate Rules with @Import"
        case .trashArtifact:
            return "Move Artifact to Trash"
        }
    }
}

extension FileOp {
    public var symbolName: String {
        switch self {
        case .writeFile:
            return "pencil.line"
        case .symlink:
            return "link"
        case .moveToTrash:
            return "trash"
        case .moveItem:
            return "arrow.right.doc.on.clipboard"
        case .mkdir:
            return "folder.badge.plus"
        }
    }
}

extension TokenCountAPIProviderID {
    public var displayName: String {
        switch self {
        case .anthropic:
            return "Anthropic (Claude count_tokens)"
        case .gemini:
            return "Google Gemini (countTokens)"
        }
    }

    public var targetAgent: AgentID {
        switch self {
        case .anthropic:
            return .claudeCode
        case .gemini:
            return .gemini
        }
    }
}
