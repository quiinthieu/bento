import BentoCore
import Foundation

/// Errors emitted while planning, previewing, applying, verifying, or undoing fixes (`PLAN.md` §6.6).
public enum BentoFixesError: Error, Equatable, Sendable, LocalizedError {
    case allowChangesDisabled
    case confirmationRequired(kind: FixKind)
    case nonInteractiveConfirmationRequired
    case unsupportedFixKind(agent: AgentID, kind: FixKind)
    case immutableScope(Scope)
    case forbiddenGitPath(String)
    case targetNotFound(String)
    case malformedConfiguration(path: String?, details: String)
    case nonIdenticalSkills(paths: [String], previewDiff: String)
    case noDuplicateRulesFound(sourcePath: String, targetPath: String)
    case toctouMismatch(path: String, expected: String?, actual: String?)
    case postApplyVerificationFailed(String)
    case fixJournalNotFound(String)
    case invalidUndoState(fixID: String, status: FixJournalStatus)
    case postApplyModified(path: String)
    case lockUnavailable(String)
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .allowChangesDisabled:
            return "Master 'Allow changes' setting is disabled. Enable 'Allow changes' or pass --apply."
        case .confirmationRequired(let kind):
            return "Fix '\(kind.rawValue)' requires explicit confirmation."
        case .nonInteractiveConfirmationRequired:
            return "Refusing to apply changes without an interactive TTY unless --yes is specified."
        case .unsupportedFixKind(let agent, let kind):
            return "Agent '\(agent.rawValue)' does not support fix '\(kind.rawValue)'."
        case .immutableScope(let scope):
            return "Artifacts in scope '\(scope)' cannot be modified."
        case .forbiddenGitPath(let path):
            return "Refusing to modify path inside .git directory: '\(path)'."
        case .targetNotFound(let details):
            return "Target artifact or configuration entry not found: \(details)"
        case .malformedConfiguration(let path, let details):
            if let path {
                return "Malformed configuration at '\(path)': \(details)"
            }
            return "Malformed configuration: \(details)"
        case .nonIdenticalSkills(let paths, _):
            return "Refusing to consolidate non-identical skill directories: \(paths.joined(separator: ", "))"
        case .noDuplicateRulesFound(let sourcePath, let targetPath):
            return "No duplicated rules found between '\(sourcePath)' and '\(targetPath)'."
        case .toctouMismatch(let path, _, _):
            return "Target '\(path)' changed on disk after the fix plan was created (TOCTOU guard)."
        case .postApplyVerificationFailed(let details):
            return "Post-apply verification failed and changes were rolled back: \(details)"
        case .fixJournalNotFound(let fixID):
            return "No fix journal entry found for ID '\(fixID)'."
        case .invalidUndoState(let fixID, let status):
            return "Fix '\(fixID)' cannot be undone because its status is '\(status.rawValue)'."
        case .postApplyModified(let path):
            return "File '\(path)' was modified after the fix was applied; pass --force to overwrite from backup."
        case .lockUnavailable(let path):
            return "Could not acquire exclusive fixes lock at '\(path)'."
        case .ioFailure(let details):
            return details
        }
    }
}
