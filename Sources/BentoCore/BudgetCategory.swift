/// Context budget bucket used for stacked visualization and category rollups.
public enum BudgetCategory: String, Sendable, Codable, CaseIterable {
    case builtInSystem
    case builtInTools
    case rules
    case skillFrontmatter
    case skillBody
    case mcpToolsLoaded
    case mcpToolsDeferred
    case subagents
    case commands
    case hooks
    case other
}
