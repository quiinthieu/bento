/// Classification of configuration artifact loaded by an AI coding agent.
public enum ArtifactKind: String, Sendable, Codable, CaseIterable {
    case settings
    case rules
    case skill
    case mcpServer
    case subagent
    case command
    case hook
    case plugin
    case outputStyle
    case ignoreFile
}
