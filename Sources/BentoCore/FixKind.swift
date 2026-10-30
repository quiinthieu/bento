/// Supported reversible configuration fix actions executed exclusively by `BentoFixes`.
public enum FixKind: String, Sendable, Codable, CaseIterable {
    case disableMCPServer
    case enableMCPServer
    case disableSkill
    case enableSkill
    case consolidateSkillsViaSymlink
    case replaceDuplicateRulesWithImport
    case trashArtifact
}
