import BentoCore
import Foundation

/// Atomic filesystem mutation primitive executed exclusively by `FixEngine` (`PLAN.md` §6.6).
public enum FileOp: Sendable, Codable, Hashable {
    case writeFile(path: String, newBytes: Data, expectedOldHash: String?)
    case symlink(atPath: String, destinationPath: String)
    case moveToTrash(path: String, expectedOldHash: String?)
    case moveItem(fromPath: String, toPath: String, expectedOldHash: String?)
    case mkdir(path: String)

    /// Every filesystem path touched by this operation.
    public var touchedPaths: [String] {
        switch self {
        case .writeFile(let path, _, _):
            return [path]
        case .symlink(let atPath, let destinationPath):
            return [atPath, destinationPath]
        case .moveToTrash(let path, _):
            return [path]
        case .moveItem(let fromPath, let toPath, _):
            return [fromPath, toPath]
        case .mkdir(let path):
            return [path]
        }
    }

    /// Primary mutated path(s) requiring backup before mutation.
    public var mutatedPaths: [String] {
        switch self {
        case .writeFile(let path, _, _):
            return [path]
        case .symlink(let atPath, _):
            return [atPath]
        case .moveToTrash(let path, _):
            return [path]
        case .moveItem(let fromPath, let toPath, _):
            return [fromPath, toPath]
        case .mkdir(let path):
            return [path]
        }
    }
}

/// Expected filesystem state recorded during planning and verified immediately prior to `apply` (`TOCTOU` guard).
public struct PathPrecondition: Sendable, Codable, Hashable {
    public enum ExpectedState: Sendable, Codable, Hashable {
        case absent
        case regularFile(sha256: String)
        case directory(treeSHA256: String)
        case symlink(destination: String)
    }

    public var path: String
    public var expectedState: ExpectedState

    public init(path: String, expectedState: ExpectedState) {
        self.path = path
        self.expectedState = expectedState
    }
}

/// Unified diff preview entry for a planned file or structural operation (`PLAN.md` §6.6, §6.7).
public struct UnifiedDiff: Sendable, Codable, Hashable {
    public var path: String
    public var summary: String
    public var patch: String

    public init(path: String, summary: String, patch: String) {
        self.path = path
        self.summary = summary
        self.patch = patch
    }
}

/// Input specification for planning one of the 7 reversible `FixKind` actions (`PLAN.md` §6.6).
public struct FixRequest: Sendable, Hashable {
    public var kind: FixKind
    public var artifacts: [Artifact]
    public var agent: AgentID?
    public var targetName: String?
    public var repoPath: String?
    public var targetRulesPath: String?
    public var canonicalSkillsRoot: String?
    public var confirmed: Bool

    /// Plans a fix targeting a single discovered `Artifact`.
    public init(
        kind: FixKind,
        artifact: Artifact,
        targetRulesPath: String? = nil,
        canonicalSkillsRoot: String? = nil,
        confirmed: Bool = false
    ) {
        self.kind = kind
        self.artifacts = [artifact]
        self.agent = artifact.agent
        self.targetName = artifact.name
        self.repoPath = nil
        self.targetRulesPath = targetRulesPath
        self.canonicalSkillsRoot = canonicalSkillsRoot
        self.confirmed = confirmed
    }

    /// Plans a multi-artifact fix (such as `consolidateSkillsViaSymlink`).
    public init(
        kind: FixKind,
        artifacts: [Artifact],
        canonicalSkillsRoot: String? = nil,
        confirmed: Bool = false
    ) {
        self.kind = kind
        self.artifacts = artifacts
        self.agent = artifacts.first?.agent
        self.targetName = artifacts.first?.name
        self.repoPath = nil
        self.targetRulesPath = nil
        self.canonicalSkillsRoot = canonicalSkillsRoot
        self.confirmed = confirmed
    }

    /// Plans a fix by agent and target name (for example re-enabling a stashed skill or MCP server).
    public init(
        kind: FixKind,
        agent: AgentID,
        targetName: String,
        repoPath: String? = nil,
        targetRulesPath: String? = nil,
        canonicalSkillsRoot: String? = nil,
        confirmed: Bool = false
    ) {
        self.kind = kind
        self.artifacts = []
        self.agent = agent
        self.targetName = targetName
        self.repoPath = repoPath
        self.targetRulesPath = targetRulesPath
        self.canonicalSkillsRoot = canonicalSkillsRoot
        self.confirmed = confirmed
    }
}

/// Complete, previewable, TOCTOU-guarded fix execution plan (`PLAN.md` §6.6).
public struct FixPlan: Sendable, Codable, Identifiable, Hashable {
    public var id: String
    public var createdAt: Date
    public var kind: FixKind
    public var agent: AgentID
    public var summary: String
    public var targetArtifactIDs: [ArtifactID]
    public var affectedPaths: [String]
    public var affectedRepoPath: String?
    public var preconditions: [PathPrecondition]
    public var operations: [FileOp]
    public var requiresConfirmation: Bool

    public init(
        id: String,
        createdAt: Date,
        kind: FixKind,
        agent: AgentID,
        summary: String,
        targetArtifactIDs: [ArtifactID],
        affectedPaths: [String],
        affectedRepoPath: String?,
        preconditions: [PathPrecondition],
        operations: [FileOp],
        requiresConfirmation: Bool
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.agent = agent
        self.summary = summary
        self.targetArtifactIDs = targetArtifactIDs
        self.affectedPaths = affectedPaths
        self.affectedRepoPath = affectedRepoPath
        self.preconditions = preconditions
        self.operations = operations
        self.requiresConfirmation = requiresConfirmation
    }
}

/// Secret-free summary persisted in `fix_journal.plan_json` (`PLAN.md` §4.2, §7).
public struct PersistedFixPlanSummary: Sendable, Codable, Hashable {
    public struct OperationSummary: Sendable, Codable, Hashable {
        public var kind: String
        public var path: String
        public var destinationPath: String?
        public var byteCount: Int?
        public var newSHA256: String?
        public var expectedOldHash: String?
    }

    public var id: String
    public var createdAt: Date
    public var kind: FixKind
    public var agent: AgentID
    public var summary: String
    public var targetArtifactIDs: [ArtifactID]
    public var affectedPaths: [String]
    public var affectedRepoPath: String?
    public var requiresConfirmation: Bool
    public var operations: [OperationSummary]

    public init(from plan: FixPlan) {
        self.id = plan.id
        self.createdAt = plan.createdAt
        self.kind = plan.kind
        self.agent = plan.agent
        self.summary = plan.summary
        self.targetArtifactIDs = plan.targetArtifactIDs
        self.affectedPaths = plan.affectedPaths
        self.affectedRepoPath = plan.affectedRepoPath
        self.requiresConfirmation = plan.requiresConfirmation
        self.operations = plan.operations.map { op in
            switch op {
            case .writeFile(let path, let newBytes, let expectedOldHash):
                return OperationSummary(
                    kind: "writeFile",
                    path: path,
                    destinationPath: nil,
                    byteCount: newBytes.count,
                    newSHA256: ContentHasher.sha256Hex(newBytes),
                    expectedOldHash: expectedOldHash
                )
            case .symlink(let atPath, let destinationPath):
                return OperationSummary(
                    kind: "symlink",
                    path: atPath,
                    destinationPath: destinationPath,
                    byteCount: nil,
                    newSHA256: nil,
                    expectedOldHash: nil
                )
            case .moveToTrash(let path, let expectedOldHash):
                return OperationSummary(
                    kind: "moveToTrash",
                    path: path,
                    destinationPath: nil,
                    byteCount: nil,
                    newSHA256: nil,
                    expectedOldHash: expectedOldHash
                )
            case .moveItem(let fromPath, let toPath, let expectedOldHash):
                return OperationSummary(
                    kind: "moveItem",
                    path: fromPath,
                    destinationPath: toPath,
                    byteCount: nil,
                    newSHA256: nil,
                    expectedOldHash: expectedOldHash
                )
            case .mkdir(let path):
                return OperationSummary(
                    kind: "mkdir",
                    path: path,
                    destinationPath: nil,
                    byteCount: nil,
                    newSHA256: nil,
                    expectedOldHash: nil
                )
            }
        }
    }
}

/// Outcome returned after a `FixPlan` is backed up, atomically applied, verified, and journaled.
public struct FixApplyResult: Sendable, Hashable {
    public var fixID: String
    public var backupDir: URL
    public var journalEntry: FixJournalEntry

    public init(fixID: String, backupDir: URL, journalEntry: FixJournalEntry) {
        self.fixID = fixID
        self.backupDir = backupDir
        self.journalEntry = journalEntry
    }
}

/// Outcome returned after `undo(fixID:)` restores all affected items from backup.
public struct FixUndoResult: Sendable, Hashable {
    public var fixID: String
    public var journalEntry: FixJournalEntry

    public init(fixID: String, journalEntry: FixJournalEntry) {
        self.fixID = fixID
        self.journalEntry = journalEntry
    }
}

/// Protocol seam allowing `BentoUI` and tests to spy on fix planning, preview, apply, and undo (`PLAN.md` §11 T15).
public protocol FixApplying: Sendable {
    func plan(
        _ request: FixRequest,
        snapshot: Snapshot,
        fixSupports: [AgentID: FixSupport]
    ) throws -> FixPlan

    func preview(_ plan: FixPlan) -> [UnifiedDiff]

    func apply(
        _ plan: FixPlan,
        allowChanges: Bool?,
        postStateVerifier: (@Sendable (FixPlan) async throws -> Bool)?
    ) async throws -> FixApplyResult

    func undo(
        fixID: String,
        allowChanges: Bool?,
        force: Bool
    ) async throws -> FixUndoResult
}
