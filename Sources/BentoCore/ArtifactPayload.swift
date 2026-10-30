/// Kind-specific structured payload carried by an `Artifact`.
public enum ArtifactPayload: Sendable, Codable, Hashable {
    case rules(RulesDoc)
    case skill(SkillDoc)
    case mcpServer(MCPServerConfig)
    case subagent(SubagentDoc)
    case command(CommandDoc)
    case hook(HookConfig)
    case settings(SettingsDoc)
    case plugin(PluginManifest)
    case other
}
