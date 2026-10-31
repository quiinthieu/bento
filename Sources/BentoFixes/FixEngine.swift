import BentoCore
import BentoParsing
import BentoStore
import Darwin
import Foundation

/// Sole configuration-writing engine (`PLAN.md` §0 Rule 3, §6.6).
///
/// Plans, previews (unified diff), backs up, atomically applies under an exclusive file lock,
/// verifies post-state with automatic rollback, journals to `BentoStore`, and undoes all 7 `FixKind`s.
public struct FixEngine: FixApplying, Sendable {
    public let homeURL: URL
    public let supportDirectory: URL
    public let store: BentoStore?
    public let fileSystem: any ReadOnlyFileSystem
    public let trashHandler: any TrashHandling
    public let now: @Sendable () -> Date

    public init(
        homeURL: URL,
        supportDirectory: URL,
        store: BentoStore? = nil,
        fileSystem: any ReadOnlyFileSystem = LocalReadOnlyFileSystem(),
        trashHandler: any TrashHandling = SystemTrashHandler(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.homeURL = homeURL.standardizedFileURL
        self.supportDirectory = supportDirectory.standardizedFileURL
        self.store = store
        self.fileSystem = fileSystem
        self.trashHandler = trashHandler
        self.now = now
    }

    // MARK: - Stash Index (`<supportDirectory>/Disabled/index.json`)

    struct DisabledStashRecord: Sendable, Codable, Hashable {
        enum EntryKind: String, Sendable, Codable, Hashable {
            case mcpServer
            case skill
        }

        var id: String
        var kind: EntryKind
        var agent: AgentID
        var name: String
        var scope: Scope
        var repoPath: String?
        var originalPath: String
        var keyPath: [String]?
        var rawJSONCSnippet: String?
        var stashedDirectoryPath: String?
        var disabledAt: Date
    }

    private struct DisabledStashIndex: Sendable, Codable, Hashable {
        var schemaVersion: Int = 1
        var entries: [DisabledStashRecord] = []
    }

    private var stashIndexURL: URL {
        supportDirectory
            .appendingPathComponent("Disabled", isDirectory: true)
            .appendingPathComponent("index.json", isDirectory: false)
    }

    // MARK: - Public API (`FixApplying`)

    public func plan(
        _ request: FixRequest,
        snapshot: Snapshot,
        fixSupports: [AgentID: FixSupport]
    ) throws -> FixPlan {
        switch request.kind {
        case .disableMCPServer:
            return try planDisableMCPServer(request, snapshot: snapshot, fixSupports: fixSupports)
        case .enableMCPServer:
            return try planEnableMCPServer(request, snapshot: snapshot, fixSupports: fixSupports)
        case .disableSkill:
            return try planDisableSkill(request, snapshot: snapshot, fixSupports: fixSupports)
        case .enableSkill:
            return try planEnableSkill(request, snapshot: snapshot, fixSupports: fixSupports)
        case .consolidateSkillsViaSymlink:
            return try planConsolidateSkills(request, snapshot: snapshot, fixSupports: fixSupports)
        case .replaceDuplicateRulesWithImport:
            return try planReplaceDuplicateRulesWithImport(request, snapshot: snapshot, fixSupports: fixSupports)
        case .trashArtifact:
            return try planTrashArtifact(request, snapshot: snapshot, fixSupports: fixSupports)
        }
    }

    public func preview(_ plan: FixPlan) -> [UnifiedDiff] {
        UnifiedDiffGenerator.preview(plan: plan, fileSystem: fileSystem)
    }

    public func apply(
        _ plan: FixPlan,
        allowChanges: Bool? = nil,
        postStateVerifier: (@Sendable (FixPlan) async throws -> Bool)? = nil
    ) async throws -> FixApplyResult {
        let effectiveAllowChanges: Bool
        if let allowChanges {
            effectiveAllowChanges = allowChanges
        } else {
            effectiveAllowChanges = (try? store?.allowChangesEnabled()) ?? false
        }

        guard effectiveAllowChanges else {
            throw BentoFixesError.allowChangesDisabled
        }

        try validateNoGitPaths(in: plan)

        return try await withFixesLock {
            // 1. TOCTOU guard: re-verify every planned precondition and operation hash right before writing.
            try verifyPreconditions(for: plan)

            // 2. Create backup directory & manifest.json.
            let timestamp = now()
            let backupDir = BackupManager.makeBackupDirectoryURL(
                supportDirectory: supportDirectory,
                fixID: plan.id,
                now: timestamp
            )
            var manifest = try BackupManager.createBackup(for: plan, at: backupDir, now: timestamp)

            let planJSON = encodePersistedPlanJSON(plan)
            var pendingEntry = FixJournalEntry(
                id: plan.id,
                createdAt: plan.createdAt,
                kind: plan.kind,
                planJSON: planJSON,
                backupDir: backupDir.path,
                status: .pending
            )
            try store?.saveFixJournalEntry(pendingEntry)

            var trashedPaths: [String] = []
            do {
                // 3. Execute FileOps atomically (preserving file modes; deletions via TrashHandler only).
                for op in plan.operations {
                    try execute(op, trashedPaths: &trashedPaths)
                }

                // 4. Built-in post-write verification (existence, hashes, symlinks, JSONC/TOML parse).
                try verifyBuiltInPostState(for: plan)

                // 5. Caller-supplied scope re-scan verifier (if provided).
                if let postStateVerifier {
                    let verified = try await postStateVerifier(plan)
                    if !verified {
                        throw BentoFixesError.postApplyVerificationFailed(
                            "Post-apply scope verification failed for fix '\(plan.id)'"
                        )
                    }
                }

                try BackupManager.finalizePostApplyState(
                    &manifest,
                    trashedPaths: trashedPaths,
                    in: backupDir
                )

                // 6. Persist `.applied` journal entry.
                pendingEntry.status = .applied
                pendingEntry.appliedAt = now()
                pendingEntry.error = nil
                try store?.saveFixJournalEntry(pendingEntry)

                return FixApplyResult(
                    fixID: plan.id,
                    backupDir: backupDir,
                    journalEntry: pendingEntry
                )
            } catch {
                // Automatic rollback from backup on any failure or post-state mismatch.
                manifest.trashedPaths = trashedPaths
                try? BackupManager.restore(manifest, from: backupDir)

                pendingEntry.status = .rolledBack
                pendingEntry.error = String(describing: error)
                try? store?.saveFixJournalEntry(pendingEntry)

                if let fixesError = error as? BentoFixesError {
                    throw fixesError
                }
                throw BentoFixesError.postApplyVerificationFailed(String(describing: error))
            }
        }
    }

    public func undo(
        fixID: String,
        allowChanges: Bool? = nil,
        force: Bool = false
    ) async throws -> FixUndoResult {
        let effectiveAllowChanges: Bool
        if let allowChanges {
            effectiveAllowChanges = allowChanges
        } else {
            effectiveAllowChanges = (try? store?.allowChangesEnabled()) ?? false
        }

        guard effectiveAllowChanges else {
            throw BentoFixesError.allowChangesDisabled
        }

        return try await withFixesLock {
            guard let store else {
                throw BentoFixesError.fixJournalNotFound(fixID)
            }
            guard var entry = try store.fetchFixJournalEntry(id: fixID) else {
                throw BentoFixesError.fixJournalNotFound(fixID)
            }
            guard entry.status == .applied else {
                throw BentoFixesError.invalidUndoState(fixID: fixID, status: entry.status)
            }

            let backupDir = URL(fileURLWithPath: entry.backupDir, isDirectory: true)
            let manifest = try BackupManager.loadManifest(from: backupDir)

            for item in manifest.items {
                try ensureNotInsideGit(path: item.originalPath)
            }

            if !force {
                try BackupManager.verifyPostApplyUnmodified(manifest)
            }

            try BackupManager.restore(manifest, from: backupDir)

            entry.status = .undone
            entry.undoneAt = now()
            entry.error = nil
            try store.saveFixJournalEntry(entry)

            return FixUndoResult(fixID: fixID, journalEntry: entry)
        }
    }

    // MARK: - 1. Disable MCP Server

    private func planDisableMCPServer(
        _ request: FixRequest,
        snapshot: Snapshot,
        fixSupports: [AgentID: FixSupport]
    ) throws -> FixPlan {
        let artifact = try resolveSingleArtifact(
            request: request,
            expectedKind: .mcpServer,
            snapshot: snapshot
        )
        try verifyCapability(agent: artifact.agent, kind: .disableMCPServer, fixSupports: fixSupports)
        try verifyMutableScope(artifact.scope)
        try ensureNotInsideGit(path: artifact.location.path)

        let repoPath = inferRepoPath(for: artifact.location.path, snapshot: snapshot)

        switch artifact.agent {
        case .claudeCode:
            let fileURL = URL(fileURLWithPath: artifact.location.path)
            if fileURL.lastPathComponent == ".mcp.json" || artifact.scope == .project {
                let repoRoot = resolveClaudeProjectRoot(forMCPFile: fileURL, snapshot: snapshot)
                let claudeDir = repoRoot.appendingPathComponent(".claude", isDirectory: true)
                let settingsLocalURL = claudeDir.appendingPathComponent("settings.local.json")
                try ensureNotInsideGit(path: settingsLocalURL.path)

                let (existingText, oldHash) = try readOptionalUTF8File(at: settingsLocalURL)
                var updated = try JSONSpanEditor.upsertStringArrayElement(
                    in: existingText ?? "{\n}\n",
                    keyPath: ["disabledMcpjsonServers"],
                    element: artifact.name
                )
                updated = try JSONSpanEditor.removeStringArrayElement(
                    in: updated,
                    keyPath: ["enabledMcpjsonServers"],
                    element: artifact.name
                )

                var ops: [FileOp] = []
                if !DirectoryHasher.lstatExists(atPath: claudeDir.path) {
                    ops.append(.mkdir(path: claudeDir.path))
                }
                ops.append(
                    .writeFile(
                        path: settingsLocalURL.path,
                        newBytes: Data(updated.utf8),
                        expectedOldHash: oldHash
                    )
                )

                return try buildPlan(
                    kind: .disableMCPServer,
                    agent: .claudeCode,
                    summary: "Disable Claude Code project MCP server '\(artifact.name)' via settings.local.json",
                    targetArtifactIDs: [artifact.id],
                    affectedRepoPath: repoRoot.path,
                    operations: ops,
                    requiresConfirmation: false
                )
            } else {
                // User or projectLocal MCP server in ~/.claude.json -> move raw JSONC snippet to Bento stash.
                let sourceURL = URL(fileURLWithPath: artifact.location.path)
                let (rawText, oldHash) = try readRequiredUTF8File(at: sourceURL)
                let keyPath = artifact.location.keyPath ?? ["mcpServers", artifact.name]
                let (updatedJSON, removedRaw) = try JSONSpanEditor.removeObjectProperty(
                    in: rawText,
                    keyPath: keyPath
                )
                guard let snippet = removedRaw else {
                    throw BentoFixesError.targetNotFound(
                        "MCP server '\(artifact.name)' not found at '\(keyPath.joined(separator: "."))'"
                    )
                }

                let inferredProjectRepo: String? =
                    (keyPath.count >= 4 && keyPath[0] == "projects") ? keyPath[1] : repoPath
                let record = DisabledStashRecord(
                    id: UUID().uuidString,
                    kind: .mcpServer,
                    agent: .claudeCode,
                    name: artifact.name,
                    scope: artifact.scope,
                    repoPath: inferredProjectRepo,
                    originalPath: sourceURL.path,
                    keyPath: keyPath,
                    rawJSONCSnippet: snippet,
                    stashedDirectoryPath: nil,
                    disabledAt: now()
                )
                let indexOps = try planStashUpsert(record: record)
                let ops =
                    [
                        FileOp.writeFile(
                            path: sourceURL.path,
                            newBytes: Data(updatedJSON.utf8),
                            expectedOldHash: oldHash
                        )
                    ] + indexOps

                return try buildPlan(
                    kind: .disableMCPServer,
                    agent: .claudeCode,
                    summary: "Disable Claude Code MCP server '\(artifact.name)' (stashed in \(Product.name) backup)",
                    targetArtifactIDs: [artifact.id],
                    affectedRepoPath: inferredProjectRepo,
                    operations: ops,
                    requiresConfirmation: false
                )
            }

        case .codex:
            let sourceURL = URL(fileURLWithPath: artifact.location.path)
            let (rawText, oldHash) = try readRequiredUTF8File(at: sourceURL)
            let sectionPath = artifact.location.keyPath ?? ["mcp_servers", artifact.name]
            let updated = try TOMLLineEditor.setBooleanInSection(
                in: rawText,
                sectionPath: sectionPath,
                key: "enabled",
                value: false
            )
            return try buildPlan(
                kind: .disableMCPServer,
                agent: .codex,
                summary: "Set enabled = false for Codex MCP server '\(artifact.name)'",
                targetArtifactIDs: [artifact.id],
                affectedRepoPath: repoPath,
                operations: [
                    .writeFile(
                        path: sourceURL.path,
                        newBytes: Data(updated.utf8),
                        expectedOldHash: oldHash
                    )
                ],
                requiresConfirmation: false
            )

        case .gemini:
            let sourceURL = URL(fileURLWithPath: artifact.location.path)
            if sourceURL.lastPathComponent == "gemini-extension.json" {
                let userSettingsURL = homeURL.appendingPathComponent(".gemini/settings.json")
                try ensureNotInsideGit(path: userSettingsURL.path)
                let (existingText, oldHash) = try readOptionalUTF8File(at: userSettingsURL)
                let updated = try JSONSpanEditor.upsertStringArrayElement(
                    in: existingText ?? "{\n}\n",
                    keyPath: ["mcp", "excluded"],
                    element: artifact.name
                )
                var ops: [FileOp] = []
                let geminiDir = userSettingsURL.deletingLastPathComponent()
                if !DirectoryHasher.lstatExists(atPath: geminiDir.path) {
                    ops.append(.mkdir(path: geminiDir.path))
                }
                ops.append(
                    .writeFile(
                        path: userSettingsURL.path,
                        newBytes: Data(updated.utf8),
                        expectedOldHash: oldHash
                    )
                )
                return try buildPlan(
                    kind: .disableMCPServer,
                    agent: .gemini,
                    summary: "Exclude Gemini extension MCP server '\(artifact.name)' in settings.json",
                    targetArtifactIDs: [artifact.id],
                    affectedRepoPath: repoPath,
                    operations: ops,
                    requiresConfirmation: false
                )
            } else {
                let (rawText, oldHash) = try readRequiredUTF8File(at: sourceURL)
                let keyPath = artifact.location.keyPath ?? ["mcpServers", artifact.name]
                let (updatedJSON, removedRaw) = try JSONSpanEditor.removeObjectProperty(
                    in: rawText,
                    keyPath: keyPath
                )
                guard let snippet = removedRaw else {
                    throw BentoFixesError.targetNotFound(
                        "Gemini MCP server '\(artifact.name)' not found at '\(keyPath.joined(separator: "."))'"
                    )
                }
                let record = DisabledStashRecord(
                    id: UUID().uuidString,
                    kind: .mcpServer,
                    agent: .gemini,
                    name: artifact.name,
                    scope: artifact.scope,
                    repoPath: repoPath,
                    originalPath: sourceURL.path,
                    keyPath: keyPath,
                    rawJSONCSnippet: snippet,
                    stashedDirectoryPath: nil,
                    disabledAt: now()
                )
                let indexOps = try planStashUpsert(record: record)
                let ops =
                    [
                        FileOp.writeFile(
                            path: sourceURL.path,
                            newBytes: Data(updatedJSON.utf8),
                            expectedOldHash: oldHash
                        )
                    ] + indexOps

                return try buildPlan(
                    kind: .disableMCPServer,
                    agent: .gemini,
                    summary: "Disable Gemini MCP server '\(artifact.name)' (stashed in \(Product.name) backup)",
                    targetArtifactIDs: [artifact.id],
                    affectedRepoPath: repoPath,
                    operations: ops,
                    requiresConfirmation: false
                )
            }

        case .copilot:
            let sourceURL = URL(fileURLWithPath: artifact.location.path)
            let (rawText, oldHash) = try readRequiredUTF8File(at: sourceURL)
            let baseKeyPath = artifact.location.keyPath ?? ["mcpServers", artifact.name]
            let updated = try JSONSpanEditor.setProperty(
                in: rawText,
                keyPath: baseKeyPath + ["enabled"],
                valueLiteral: "false"
            )
            return try buildPlan(
                kind: .disableMCPServer,
                agent: .copilot,
                summary: "Set enabled = false for Copilot MCP server '\(artifact.name)'",
                targetArtifactIDs: [artifact.id],
                affectedRepoPath: repoPath,
                operations: [
                    .writeFile(
                        path: sourceURL.path,
                        newBytes: Data(updated.utf8),
                        expectedOldHash: oldHash
                    )
                ],
                requiresConfirmation: false
            )

        case .cursor, .windsurf:
            throw BentoFixesError.unsupportedFixKind(agent: artifact.agent, kind: .disableMCPServer)
        }
    }

    // MARK: - 2. Enable MCP Server

    private func planEnableMCPServer(
        _ request: FixRequest,
        snapshot: Snapshot,
        fixSupports: [AgentID: FixSupport]
    ) throws -> FixPlan {
        let agent = try resolveAgent(from: request, snapshot: snapshot)
        try verifyCapability(agent: agent, kind: .enableMCPServer, fixSupports: fixSupports)

        switch agent {
        case .claudeCode:
            if let artifact = request.artifacts.first,
                URL(fileURLWithPath: artifact.location.path).lastPathComponent == ".mcp.json"
                    || artifact.scope == .project
            {
                try verifyMutableScope(artifact.scope)
                let fileURL = URL(fileURLWithPath: artifact.location.path)
                let repoRoot = resolveClaudeProjectRoot(forMCPFile: fileURL, snapshot: snapshot)
                let claudeDir = repoRoot.appendingPathComponent(".claude", isDirectory: true)
                let settingsLocalURL = claudeDir.appendingPathComponent("settings.local.json")
                try ensureNotInsideGit(path: settingsLocalURL.path)

                let (existingText, oldHash) = try readOptionalUTF8File(at: settingsLocalURL)
                let baseText = existingText ?? "{\n}\n"
                var updated = try JSONSpanEditor.removeStringArrayElement(
                    in: baseText,
                    keyPath: ["disabledMcpjsonServers"],
                    element: artifact.name
                )
                let parsed = try JSONCParser.parseObject(updated, redactSecrets: false)
                if parsed["enableAllProjectMcpServers"] != .bool(true) {
                    updated = try JSONSpanEditor.upsertStringArrayElement(
                        in: updated,
                        keyPath: ["enabledMcpjsonServers"],
                        element: artifact.name
                    )
                }

                var ops: [FileOp] = []
                if !DirectoryHasher.lstatExists(atPath: claudeDir.path) {
                    ops.append(.mkdir(path: claudeDir.path))
                }
                ops.append(
                    .writeFile(
                        path: settingsLocalURL.path,
                        newBytes: Data(updated.utf8),
                        expectedOldHash: oldHash
                    )
                )

                return try buildPlan(
                    kind: .enableMCPServer,
                    agent: .claudeCode,
                    summary: "Enable Claude Code project MCP server '\(artifact.name)' in settings.local.json",
                    targetArtifactIDs: [artifact.id],
                    affectedRepoPath: repoRoot.path,
                    operations: ops,
                    requiresConfirmation: false
                )
            }

            // Check stash first for user / projectLocal ~/.claude.json servers.
            if let name = request.targetName ?? request.artifacts.first?.name,
                let stashed = try findStashedRecord(
                    kind: .mcpServer,
                    agent: .claudeCode,
                    name: name,
                    repoPath: request.repoPath
                )
            {
                return try planRestoreStashedMCPServer(stashed)
            }

            // Fallback: check if snapshot contains a project .mcp.json artifact matching targetName.
            if let name = request.targetName,
                let projectArtifact = snapshot.artifacts.first(where: {
                    $0.agent == .claudeCode && $0.kind == .mcpServer && $0.name == name
                })
            {
                return try planEnableMCPServer(
                    FixRequest(kind: .enableMCPServer, artifact: projectArtifact, confirmed: request.confirmed),
                    snapshot: snapshot,
                    fixSupports: fixSupports
                )
            }

            throw BentoFixesError.targetNotFound(
                "No disabled Claude Code MCP server matching '\(request.targetName ?? "")'"
            )

        case .codex:
            let artifact = try resolveSingleArtifact(
                request: request,
                expectedKind: .mcpServer,
                snapshot: snapshot
            )
            try verifyMutableScope(artifact.scope)
            let sourceURL = URL(fileURLWithPath: artifact.location.path)
            try ensureNotInsideGit(path: sourceURL.path)
            let (rawText, oldHash) = try readRequiredUTF8File(at: sourceURL)
            let sectionPath = artifact.location.keyPath ?? ["mcp_servers", artifact.name]
            let updated = try TOMLLineEditor.setBooleanInSection(
                in: rawText,
                sectionPath: sectionPath,
                key: "enabled",
                value: true
            )
            let repoPath = inferRepoPath(for: sourceURL.path, snapshot: snapshot)
            return try buildPlan(
                kind: .enableMCPServer,
                agent: .codex,
                summary: "Set enabled = true for Codex MCP server '\(artifact.name)'",
                targetArtifactIDs: [artifact.id],
                affectedRepoPath: repoPath,
                operations: [
                    .writeFile(
                        path: sourceURL.path,
                        newBytes: Data(updated.utf8),
                        expectedOldHash: oldHash
                    )
                ],
                requiresConfirmation: false
            )

        case .gemini:
            if let name = request.targetName ?? request.artifacts.first?.name,
                let stashed = try findStashedRecord(
                    kind: .mcpServer,
                    agent: .gemini,
                    name: name,
                    repoPath: request.repoPath
                )
            {
                return try planRestoreStashedMCPServer(stashed)
            }

            // Otherwise check if it's an excluded extension MCP server in ~/.gemini/settings.json.
            let artifact = try resolveSingleArtifact(
                request: request,
                expectedKind: .mcpServer,
                snapshot: snapshot
            )
            try verifyMutableScope(artifact.scope)
            let userSettingsURL = homeURL.appendingPathComponent(".gemini/settings.json")
            try ensureNotInsideGit(path: userSettingsURL.path)
            let (rawText, oldHash) = try readRequiredUTF8File(at: userSettingsURL)
            let updated = try JSONSpanEditor.removeStringArrayElement(
                in: rawText,
                keyPath: ["mcp", "excluded"],
                element: artifact.name
            )
            return try buildPlan(
                kind: .enableMCPServer,
                agent: .gemini,
                summary: "Re-enable Gemini MCP server '\(artifact.name)' in settings.json",
                targetArtifactIDs: [artifact.id],
                affectedRepoPath: inferRepoPath(for: artifact.location.path, snapshot: snapshot),
                operations: [
                    .writeFile(
                        path: userSettingsURL.path,
                        newBytes: Data(updated.utf8),
                        expectedOldHash: oldHash
                    )
                ],
                requiresConfirmation: false
            )

        case .copilot:
            let artifact = try resolveSingleArtifact(
                request: request,
                expectedKind: .mcpServer,
                snapshot: snapshot
            )
            try verifyMutableScope(artifact.scope)
            let sourceURL = URL(fileURLWithPath: artifact.location.path)
            try ensureNotInsideGit(path: sourceURL.path)
            let (rawText, oldHash) = try readRequiredUTF8File(at: sourceURL)
            let baseKeyPath = artifact.location.keyPath ?? ["mcpServers", artifact.name]
            let updated = try JSONSpanEditor.setProperty(
                in: rawText,
                keyPath: baseKeyPath + ["enabled"],
                valueLiteral: "true"
            )
            return try buildPlan(
                kind: .enableMCPServer,
                agent: .copilot,
                summary: "Set enabled = true for Copilot MCP server '\(artifact.name)'",
                targetArtifactIDs: [artifact.id],
                affectedRepoPath: inferRepoPath(for: sourceURL.path, snapshot: snapshot),
                operations: [
                    .writeFile(
                        path: sourceURL.path,
                        newBytes: Data(updated.utf8),
                        expectedOldHash: oldHash
                    )
                ],
                requiresConfirmation: false
            )

        case .cursor, .windsurf:
            throw BentoFixesError.unsupportedFixKind(agent: agent, kind: .enableMCPServer)
        }
    }

    private func planRestoreStashedMCPServer(_ record: DisabledStashRecord) throws -> FixPlan {
        guard let keyPath = record.keyPath, let snippet = record.rawJSONCSnippet else {
            throw BentoFixesError.malformedConfiguration(
                path: record.originalPath,
                details: "Stashed MCP entry '\(record.name)' is missing keyPath or raw snippet"
            )
        }
        try ensureNotInsideGit(path: record.originalPath)
        let targetURL = URL(fileURLWithPath: record.originalPath)
        let (existingText, oldHash) = try readOptionalUTF8File(at: targetURL)
        let updated = try JSONSpanEditor.setProperty(
            in: existingText ?? "{\n}\n",
            keyPath: keyPath,
            valueLiteral: snippet
        )
        let indexOps = try planStashRemove(recordID: record.id)
        let ops =
            [
                FileOp.writeFile(
                    path: targetURL.path,
                    newBytes: Data(updated.utf8),
                    expectedOldHash: oldHash
                )
            ] + indexOps

        return try buildPlan(
            kind: .enableMCPServer,
            agent: record.agent,
            summary: "Re-enable \(record.agent.rawValue) MCP server '\(record.name)' from \(Product.name) stash",
            targetArtifactIDs: [],
            affectedRepoPath: record.repoPath,
            operations: ops,
            requiresConfirmation: false
        )
    }

    // MARK: - 3. Disable Skill & 4. Enable Skill

    private func planDisableSkill(
        _ request: FixRequest,
        snapshot: Snapshot,
        fixSupports: [AgentID: FixSupport]
    ) throws -> FixPlan {
        let artifact = try resolveSingleArtifact(
            request: request,
            expectedKind: .skill,
            snapshot: snapshot
        )
        try verifyCapability(agent: artifact.agent, kind: .disableSkill, fixSupports: fixSupports)
        try verifyMutableScope(artifact.scope)

        let skillDir = Self.skillDirectoryURL(for: artifact)
        try ensureNotInsideGit(path: skillDir.path)
        guard DirectoryHasher.lstatExists(atPath: skillDir.path) else {
            throw BentoFixesError.targetNotFound("Skill directory not found at '\(skillDir.path)'")
        }

        let expectedHash: String? = {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: skillDir.path),
                (attrs[.type] as? FileAttributeType) == .typeDirectory
            {
                return try? DirectoryHasher.treeHash(at: skillDir)
            }
            return nil
        }()

        let pathKey = String(ContentHasher.sha256Hex(Data(skillDir.path.utf8)).prefix(10))
        let stashParent =
            supportDirectory
            .appendingPathComponent("Disabled", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(artifact.agent.rawValue, isDirectory: true)
            .appendingPathComponent("\(artifact.scope.rawValue)-\(pathKey)", isDirectory: true)
        let stashDest = stashParent.appendingPathComponent(skillDir.lastPathComponent, isDirectory: true)

        let repoPath = inferRepoPath(for: skillDir.path, snapshot: snapshot)
        let record = DisabledStashRecord(
            id: UUID().uuidString,
            kind: .skill,
            agent: artifact.agent,
            name: artifact.name,
            scope: artifact.scope,
            repoPath: repoPath,
            originalPath: skillDir.path,
            keyPath: nil,
            rawJSONCSnippet: nil,
            stashedDirectoryPath: stashDest.path,
            disabledAt: now()
        )
        let indexOps = try planStashUpsert(record: record)

        var ops: [FileOp] = []
        if !DirectoryHasher.lstatExists(atPath: stashParent.path) {
            ops.append(.mkdir(path: stashParent.path))
        }
        ops.append(
            .moveItem(
                fromPath: skillDir.path,
                toPath: stashDest.path,
                expectedOldHash: expectedHash
            )
        )
        ops.append(contentsOf: indexOps)

        return try buildPlan(
            kind: .disableSkill,
            agent: artifact.agent,
            summary: "Disable \(artifact.agent.rawValue) skill '\(artifact.name)'",
            targetArtifactIDs: [artifact.id],
            affectedRepoPath: repoPath,
            operations: ops,
            requiresConfirmation: false
        )
    }

    private func planEnableSkill(
        _ request: FixRequest,
        snapshot: Snapshot,
        fixSupports: [AgentID: FixSupport]
    ) throws -> FixPlan {
        let agent = try resolveAgent(from: request, snapshot: snapshot)
        try verifyCapability(agent: agent, kind: .enableSkill, fixSupports: fixSupports)

        guard let targetName = request.targetName ?? request.artifacts.first?.name,
            let record = try findStashedRecord(
                kind: .skill,
                agent: agent,
                name: targetName,
                repoPath: request.repoPath
            ),
            let stashedDirPath = record.stashedDirectoryPath
        else {
            throw BentoFixesError.targetNotFound(
                "No disabled \(agent.rawValue) skill matching '\(request.targetName ?? "")'"
            )
        }

        try ensureNotInsideGit(path: record.originalPath)
        guard DirectoryHasher.lstatExists(atPath: stashedDirPath) else {
            throw BentoFixesError.targetNotFound("Stashed skill directory missing at '\(stashedDirPath)'")
        }
        if DirectoryHasher.lstatExists(atPath: record.originalPath) {
            throw BentoFixesError.ioFailure(
                "Cannot re-enable skill '\(record.name)': destination '\(record.originalPath)' already exists"
            )
        }

        let stashedURL = URL(fileURLWithPath: stashedDirPath, isDirectory: true)
        let expectedHash = try? DirectoryHasher.treeHash(at: stashedURL)
        let originalParent = URL(fileURLWithPath: record.originalPath).deletingLastPathComponent()
        let indexOps = try planStashRemove(recordID: record.id)

        var ops: [FileOp] = []
        if !DirectoryHasher.lstatExists(atPath: originalParent.path) {
            ops.append(.mkdir(path: originalParent.path))
        }
        ops.append(
            .moveItem(
                fromPath: stashedDirPath,
                toPath: record.originalPath,
                expectedOldHash: expectedHash
            )
        )
        ops.append(contentsOf: indexOps)

        return try buildPlan(
            kind: .enableSkill,
            agent: agent,
            summary: "Re-enable \(agent.rawValue) skill '\(record.name)'",
            targetArtifactIDs: [],
            affectedRepoPath: record.repoPath,
            operations: ops,
            requiresConfirmation: false
        )
    }

    // MARK: - 5. Consolidate Skills via Symlink

    private func planConsolidateSkills(
        _ request: FixRequest,
        snapshot: Snapshot,
        fixSupports: [AgentID: FixSupport]
    ) throws -> FixPlan {
        if let explicitAgent = request.agent {
            try verifyCapability(agent: explicitAgent, kind: .consolidateSkillsViaSymlink, fixSupports: fixSupports)
        }

        var candidates = request.artifacts
        if candidates.isEmpty, let targetName = request.targetName {
            candidates = snapshot.artifacts.filter { item in
                item.kind == .skill
                    && (request.agent == nil || item.agent == request.agent)
                    && (item.name == targetName || item.id.rawValue == targetName || item.location.path == targetName)
            }
        } else if candidates.count == 1, let single = candidates.first, single.kind == .skill {
            try verifyCapability(agent: single.agent, kind: .consolidateSkillsViaSymlink, fixSupports: fixSupports)
            candidates = snapshot.artifacts.filter {
                $0.kind == .skill
                    && $0.name == single.name
                    && (fixSupports[$0.agent]?.supportedKinds.contains(.consolidateSkillsViaSymlink) == true)
            }
        }

        guard !candidates.isEmpty else {
            throw BentoFixesError.targetNotFound("No skill artifacts supplied for consolidation")
        }

        var uniqueDirs: [URL] = []
        var seenDirPaths: Set<String> = []
        var itemsByDirPath: [String: [Artifact]] = [:]

        for item in candidates {
            guard item.kind == .skill else {
                throw BentoFixesError.targetNotFound("Artifact '\(item.name)' is not a skill")
            }
            try verifyMutableScope(item.scope)
            let dir = URL(
                fileURLWithPath: BackupManager.normalizeLexicalPath(Self.skillDirectoryURL(for: item).path),
                isDirectory: true
            )
            try ensureNotInsideGit(path: dir.path)
            if seenDirPaths.insert(dir.path).inserted {
                uniqueDirs.append(dir)
            }
            itemsByDirPath[dir.path, default: []].append(item)
        }

        // Every physical skill directory must be owned by at least one agent that supports skill consolidation.
        for dir in uniqueDirs {
            let owners = itemsByDirPath[dir.path] ?? []
            let hasSupportedOwner = owners.contains {
                fixSupports[$0.agent]?.supportedKinds.contains(.consolidateSkillsViaSymlink) == true
            }
            if !hasSupportedOwner, let firstOwner = owners.first {
                throw BentoFixesError.unsupportedFixKind(agent: firstOwner.agent, kind: .consolidateSkillsViaSymlink)
            }
        }

        guard
            let primary = candidates.first(where: {
                fixSupports[$0.agent]?.supportedKinds.contains(.consolidateSkillsViaSymlink) == true
            })
        else {
            throw BentoFixesError.unsupportedFixKind(
                agent: candidates[0].agent,
                kind: .consolidateSkillsViaSymlink
            )
        }

        guard !uniqueDirs.isEmpty else {
            throw BentoFixesError.targetNotFound("No skill directories found to consolidate")
        }

        let canonicalRootPath: String
        if let explicitRoot = request.canonicalSkillsRoot, !explicitRoot.isEmpty {
            canonicalRootPath = BackupManager.normalizeLexicalPath(explicitRoot)
        } else if let storedRoot = try? store?.canonicalSkillsDirectory(), !storedRoot.isEmpty {
            canonicalRootPath = BackupManager.normalizeLexicalPath(storedRoot)
        } else {
            canonicalRootPath = homeURL.appendingPathComponent(".agents/skills", isDirectory: true).path
        }

        let skillFolderName = uniqueDirs[0].lastPathComponent
        let canonicalDir = URL(fileURLWithPath: canonicalRootPath, isDirectory: true)
            .appendingPathComponent(skillFolderName, isDirectory: true)
        let canonicalPath = BackupManager.normalizeLexicalPath(canonicalDir.path)
        try ensureNotInsideGit(path: canonicalPath)

        // Verify all candidate skill trees (and canonicalDir if it already exists) have identical content hashes!
        let referenceDir = uniqueDirs[0]
        let referenceHash = try DirectoryHasher.treeHash(
            at: referenceDir.resolvingSymlinksInPath(),
            ignoreDSStore: true
        )

        var dirsToCompare = uniqueDirs
        if DirectoryHasher.lstatExists(atPath: canonicalPath) && !seenDirPaths.contains(canonicalPath) {
            dirsToCompare.append(URL(fileURLWithPath: canonicalPath, isDirectory: true))
        }

        for dir in dirsToCompare.dropFirst() {
            let hash = try DirectoryHasher.treeHash(
                at: dir.resolvingSymlinksInPath(),
                ignoreDSStore: true
            )
            if hash != referenceHash {
                let diff = try UnifiedDiffGenerator.directoryTreeDiff(
                    dirA: referenceDir.resolvingSymlinksInPath(),
                    dirB: dir.resolvingSymlinksInPath()
                )
                throw BentoFixesError.nonIdenticalSkills(
                    paths: [referenceDir.path, dir.path],
                    previewDiff: diff
                )
            }
        }

        var ops: [FileOp] = []
        let canonicalExists = DirectoryHasher.lstatExists(atPath: canonicalPath)
        let canonicalParentPath = (canonicalPath as NSString).deletingLastPathComponent

        var donorPath: String?
        if !canonicalExists {
            guard
                let donor = uniqueDirs.first(where: { dir in
                    guard let attrs = try? FileManager.default.attributesOfItem(atPath: dir.path) else {
                        return false
                    }
                    return (attrs[.type] as? FileAttributeType) == .typeDirectory
                })
            else {
                throw BentoFixesError.targetNotFound("No concrete skill directory available to populate canonical copy")
            }
            donorPath = donor.path
            let donorExactHash = try DirectoryHasher.treeHash(at: donor)
            if !DirectoryHasher.lstatExists(atPath: canonicalParentPath) {
                ops.append(.mkdir(path: canonicalParentPath))
            }
            ops.append(
                .moveItem(
                    fromPath: donor.path,
                    toPath: canonicalPath,
                    expectedOldHash: donorExactHash
                )
            )
            ops.append(.symlink(atPath: donor.path, destinationPath: canonicalPath))
        }

        for dir in uniqueDirs {
            if dir.path == canonicalPath || dir.path == donorPath {
                continue
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
            let fileType = attrs[.type] as? FileAttributeType
            if fileType == .typeSymbolicLink,
                let currentDest = try? FileManager.default.destinationOfSymbolicLink(atPath: dir.path),
                BackupManager.normalizeLexicalPath(currentDest) == canonicalPath
            {
                continue
            }
            let exactHash: String? =
                (fileType == .typeDirectory) ? (try? DirectoryHasher.treeHash(at: dir)) : nil
            ops.append(.moveToTrash(path: dir.path, expectedOldHash: exactHash))
            ops.append(.symlink(atPath: dir.path, destinationPath: canonicalPath))
        }

        return try buildPlan(
            kind: .consolidateSkillsViaSymlink,
            agent: primary.agent,
            summary: "Consolidate \(uniqueDirs.count) identical '\(primary.name)' skill copies to '\(canonicalPath)'",
            targetArtifactIDs: candidates.map(\.id),
            affectedRepoPath: nil,
            operations: ops,
            requiresConfirmation: false
        )
    }

    // MARK: - 6. Replace Duplicate Rules with `@AGENTS.md` Import

    private func planReplaceDuplicateRulesWithImport(
        _ request: FixRequest,
        snapshot: Snapshot,
        fixSupports: [AgentID: FixSupport]
    ) throws -> FixPlan {
        let artifact = try resolveSingleArtifact(
            request: request,
            expectedKind: .rules,
            snapshot: snapshot
        )
        try verifyCapability(
            agent: artifact.agent,
            kind: .replaceDuplicateRulesWithImport,
            fixSupports: fixSupports
        )
        guard fixSupports[artifact.agent]?.supportsAtImports == true else {
            throw BentoFixesError.unsupportedFixKind(
                agent: artifact.agent,
                kind: .replaceDuplicateRulesWithImport
            )
        }
        try verifyMutableScope(artifact.scope)

        let sourceURL = URL(fileURLWithPath: BackupManager.normalizeLexicalPath(artifact.location.path))
        try ensureNotInsideGit(path: sourceURL.path)

        let targetURL: URL
        if let explicitTarget = request.targetRulesPath, !explicitTarget.isEmpty {
            targetURL = URL(fileURLWithPath: BackupManager.normalizeLexicalPath(explicitTarget))
        } else {
            targetURL = sourceURL.deletingLastPathComponent().appendingPathComponent("AGENTS.md")
        }

        if sourceURL.path == targetURL.path {
            throw BentoFixesError.noDuplicateRulesFound(
                sourcePath: sourceURL.path,
                targetPath: targetURL.path
            )
        }
        guard fileSystem.exists(targetURL) else {
            throw BentoFixesError.targetNotFound("Import target rules file not found at '\(targetURL.path)'")
        }

        let (sourceRaw, oldHash) = try readRequiredUTF8File(at: sourceURL)
        let (targetRaw, _) = try readRequiredUTF8File(at: targetURL)

        let relImportPath = Self.relativePath(fromDirectory: sourceURL.deletingLastPathComponent(), toFile: targetURL)
        let directive = "@\(relImportPath)"
        let rewritten = try Self.replaceDuplicateRuleLines(
            sourceText: sourceRaw,
            targetText: targetRaw,
            importDirective: directive,
            sourcePath: sourceURL.path,
            targetPath: targetURL.path
        )

        return try buildPlan(
            kind: .replaceDuplicateRulesWithImport,
            agent: artifact.agent,
            summary: "Replace duplicated rules in '\(sourceURL.lastPathComponent)' with '\(directive)'",
            targetArtifactIDs: [artifact.id],
            affectedRepoPath: inferRepoPath(for: sourceURL.path, snapshot: snapshot),
            operations: [
                .writeFile(
                    path: sourceURL.path,
                    newBytes: Data(rewritten.utf8),
                    expectedOldHash: oldHash
                )
            ],
            requiresConfirmation: false
        )
    }

    // MARK: - 7. Trash Artifact (Confirmation Required)

    private func planTrashArtifact(
        _ request: FixRequest,
        snapshot: Snapshot,
        fixSupports: [AgentID: FixSupport]
    ) throws -> FixPlan {
        let artifact = try resolveSingleArtifact(
            request: request,
            expectedKind: nil,
            snapshot: snapshot
        )
        try verifyCapability(agent: artifact.agent, kind: .trashArtifact, fixSupports: fixSupports)
        try verifyMutableScope(artifact.scope)

        guard request.confirmed else {
            throw BentoFixesError.confirmationRequired(kind: .trashArtifact)
        }

        let targetURL =
            (artifact.kind == .skill)
            ? Self.skillDirectoryURL(for: artifact)
            : URL(fileURLWithPath: artifact.location.path)
        let normalizedPath = BackupManager.normalizeLexicalPath(targetURL.path)
        try ensureNotInsideGit(path: normalizedPath)

        guard DirectoryHasher.lstatExists(atPath: normalizedPath) else {
            throw BentoFixesError.targetNotFound("Artifact path not found on disk: '\(normalizedPath)'")
        }

        let expectedHash: String? = {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: normalizedPath) {
                let type = attrs[.type] as? FileAttributeType
                if type == .typeDirectory {
                    return try? DirectoryHasher.treeHash(at: URL(fileURLWithPath: normalizedPath, isDirectory: true))
                } else if type == .typeRegular {
                    if let bytes = try? Data(contentsOf: URL(fileURLWithPath: normalizedPath)) {
                        return ContentHasher.sha256Hex(bytes)
                    }
                }
            }
            return nil
        }()

        return try buildPlan(
            kind: .trashArtifact,
            agent: artifact.agent,
            summary: "Move \(artifact.agent.rawValue) \(artifact.kind.rawValue) '\(artifact.name)' to Trash",
            targetArtifactIDs: [artifact.id],
            affectedRepoPath: inferRepoPath(for: normalizedPath, snapshot: snapshot),
            operations: [
                .moveToTrash(path: normalizedPath, expectedOldHash: expectedHash)
            ],
            requiresConfirmation: true
        )
    }

    // MARK: - Execution, Verification & Locking Helpers

    private func execute(_ op: FileOp, trashedPaths: inout [String]) throws {
        let fm = FileManager.default
        switch op {
        case .writeFile(let path, let newBytes, _):
            try ensureNotInsideGit(path: path)
            try AtomicFileWriter.writeAtomically(
                bytes: newBytes,
                to: URL(fileURLWithPath: path)
            )

        case .symlink(let atPath, let destinationPath):
            try ensureNotInsideGit(path: atPath)
            let parent = URL(fileURLWithPath: atPath).deletingLastPathComponent()
            if !DirectoryHasher.lstatExists(atPath: parent.path) {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            if DirectoryHasher.lstatExists(atPath: atPath) {
                try fm.removeItem(atPath: atPath)
            }
            try fm.createSymbolicLink(atPath: atPath, withDestinationPath: destinationPath)

        case .moveToTrash(let path, _):
            try ensureNotInsideGit(path: path)
            let resulting = try trashHandler.trashItem(at: URL(fileURLWithPath: path))
            trashedPaths.append(resulting.path)

        case .moveItem(let fromPath, let toPath, _):
            try ensureNotInsideGit(path: fromPath)
            try ensureNotInsideGit(path: toPath)
            let parent = URL(fileURLWithPath: toPath).deletingLastPathComponent()
            if !DirectoryHasher.lstatExists(atPath: parent.path) {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            if DirectoryHasher.lstatExists(atPath: toPath) {
                try fm.removeItem(atPath: toPath)
            }
            try fm.moveItem(atPath: fromPath, toPath: toPath)

        case .mkdir(let path):
            try ensureNotInsideGit(path: path)
            try fm.createDirectory(
                at: URL(fileURLWithPath: path, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    private func verifyPreconditions(for plan: FixPlan) throws {
        for precondition in plan.preconditions {
            let actual = try DirectoryHasher.currentState(atPath: precondition.path)
            if actual != precondition.expectedState {
                throw BentoFixesError.toctouMismatch(
                    path: precondition.path,
                    expected: String(describing: precondition.expectedState),
                    actual: String(describing: actual)
                )
            }
        }

        for op in plan.operations {
            switch op {
            case .writeFile(let path, _, let expectedOldHash):
                if let expectedOldHash {
                    let state = try DirectoryHasher.currentState(atPath: path)
                    guard state == .regularFile(sha256: expectedOldHash) else {
                        throw BentoFixesError.toctouMismatch(
                            path: path,
                            expected: expectedOldHash,
                            actual: String(describing: state)
                        )
                    }
                }
            case .moveToTrash(let path, let expectedOldHash),
                .moveItem(let path, _, let expectedOldHash):
                if let expectedOldHash {
                    let state = try DirectoryHasher.currentState(atPath: path)
                    let matches =
                        (state == .regularFile(sha256: expectedOldHash))
                        || (state == .directory(treeSHA256: expectedOldHash))
                    if !matches {
                        throw BentoFixesError.toctouMismatch(
                            path: path,
                            expected: expectedOldHash,
                            actual: String(describing: state)
                        )
                    }
                }
            case .symlink, .mkdir:
                break
            }
        }
    }

    private func verifyBuiltInPostState(for plan: FixPlan) throws {
        // Track the final operation per primary path so multi-step sequences (trash -> symlink) verify final state.
        var lastExpectationByPath: [String: FileOp] = [:]
        for op in plan.operations {
            switch op {
            case .writeFile(let path, _, _):
                lastExpectationByPath[BackupManager.normalizeLexicalPath(path)] = op
            case .symlink(let atPath, _):
                lastExpectationByPath[BackupManager.normalizeLexicalPath(atPath)] = op
            case .moveToTrash(let path, _):
                lastExpectationByPath[BackupManager.normalizeLexicalPath(path)] = op
            case .moveItem(let fromPath, let toPath, _):
                let normFrom = BackupManager.normalizeLexicalPath(fromPath)
                let normTo = BackupManager.normalizeLexicalPath(toPath)
                lastExpectationByPath[normFrom] = .moveToTrash(path: normFrom, expectedOldHash: nil)
                lastExpectationByPath[normTo] = .mkdir(path: normTo)
            case .mkdir(let path):
                let norm = BackupManager.normalizeLexicalPath(path)
                if lastExpectationByPath[norm] == nil {
                    lastExpectationByPath[norm] = op
                }
            }
        }

        for (path, op) in lastExpectationByPath {
            switch op {
            case .writeFile(_, let newBytes, _):
                let state = try DirectoryHasher.currentState(atPath: path)
                let expectedHash = ContentHasher.sha256Hex(newBytes)
                guard state == .regularFile(sha256: expectedHash) else {
                    throw BentoFixesError.postApplyVerificationFailed(
                        "Post-write hash mismatch at '\(path)'"
                    )
                }
                let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
                if ext == "json" || ext == "jsonc" {
                    _ = try JSONCParser.parseValue(newBytes, redactSecrets: false)
                } else if ext == "toml" {
                    _ = try TOMLParser.parseObject(newBytes, redactSecrets: false)
                }

            case .symlink(_, let destinationPath):
                let state = try DirectoryHasher.currentState(atPath: path)
                guard state == .symlink(destination: destinationPath) else {
                    throw BentoFixesError.postApplyVerificationFailed(
                        "Expected symlink at '\(path)' -> '\(destinationPath)'"
                    )
                }

            case .moveToTrash:
                if DirectoryHasher.lstatExists(atPath: path) {
                    throw BentoFixesError.postApplyVerificationFailed(
                        "Expected '\(path)' to be removed"
                    )
                }

            case .mkdir, .moveItem:
                if !DirectoryHasher.lstatExists(atPath: path) {
                    throw BentoFixesError.postApplyVerificationFailed(
                        "Expected '\(path)' to exist after apply"
                    )
                }
            }
        }
    }

    private func withFixesLock<T>(_ body: () async throws -> T) async throws -> T {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let lockPath = supportDirectory.appendingPathComponent("fixes.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw BentoFixesError.lockUnavailable(lockPath)
        }
        defer {
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
        }

        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw BentoFixesError.lockUnavailable(lockPath)
        }

        return try await body()
    }

    // MARK: - Plan Construction & Validation Helpers

    private func buildPlan(
        kind: FixKind,
        agent: AgentID,
        summary: String,
        targetArtifactIDs: [ArtifactID],
        affectedRepoPath: String?,
        operations: [FileOp],
        requiresConfirmation: Bool
    ) throws -> FixPlan {
        var affected: [String] = []
        var seenAffected: Set<String> = []
        var preconditions: [PathPrecondition] = []
        var seenPrecond: Set<String> = []

        for op in operations {
            for rawPath in op.touchedPaths {
                let norm = BackupManager.normalizeLexicalPath(rawPath)
                try ensureNotInsideGit(path: norm)
            }
            for rawPath in op.mutatedPaths {
                let norm = BackupManager.normalizeLexicalPath(rawPath)
                if seenAffected.insert(norm).inserted {
                    affected.append(norm)
                }
                if seenPrecond.insert(norm).inserted {
                    let state = try DirectoryHasher.currentState(atPath: norm)
                    preconditions.append(PathPrecondition(path: norm, expectedState: state))
                }
            }
        }

        let plan = FixPlan(
            id: "fix-\(UUID().uuidString.lowercased())",
            createdAt: now(),
            kind: kind,
            agent: agent,
            summary: summary,
            targetArtifactIDs: targetArtifactIDs,
            affectedPaths: affected,
            affectedRepoPath: affectedRepoPath,
            preconditions: preconditions,
            operations: operations,
            requiresConfirmation: requiresConfirmation
        )
        try validateNoGitPaths(in: plan)
        return plan
    }

    private func validateNoGitPaths(in plan: FixPlan) throws {
        for path in plan.affectedPaths {
            try ensureNotInsideGit(path: path)
        }
        for op in plan.operations {
            for path in op.touchedPaths {
                try ensureNotInsideGit(path: path)
            }
        }
    }

    private func ensureNotInsideGit(path: String) throws {
        let lexicalComponents = BackupManager.normalizeLexicalPath(path).split(separator: "/")
        if lexicalComponents.contains(".git") {
            throw BentoFixesError.forbiddenGitPath(path)
        }
        let resolvedComponents = URL(fileURLWithPath: path).resolvingSymlinksInPath().path.split(separator: "/")
        if resolvedComponents.contains(".git") {
            throw BentoFixesError.forbiddenGitPath(path)
        }
    }

    private func verifyCapability(
        agent: AgentID,
        kind: FixKind,
        fixSupports: [AgentID: FixSupport]
    ) throws {
        guard let support = fixSupports[agent], support.supportedKinds.contains(kind) else {
            throw BentoFixesError.unsupportedFixKind(agent: agent, kind: kind)
        }
    }

    private func verifyMutableScope(_ scope: Scope) throws {
        if scope == .managed || scope == .builtIn {
            throw BentoFixesError.immutableScope(scope)
        }
    }

    private func resolveAgent(from request: FixRequest, snapshot: Snapshot) throws -> AgentID {
        if let agent = request.agent {
            return agent
        }
        if let first = request.artifacts.first {
            return first.agent
        }
        if let targetName = request.targetName,
            let match = snapshot.artifacts.first(where: { $0.name == targetName })
        {
            return match.agent
        }
        throw BentoFixesError.targetNotFound("Unable to determine target agent for fix '\(request.kind.rawValue)'")
    }

    private func resolveSingleArtifact(
        request: FixRequest,
        expectedKind: ArtifactKind?,
        snapshot: Snapshot
    ) throws -> Artifact {
        if let first = request.artifacts.first {
            if let expectedKind, first.kind != expectedKind {
                throw BentoFixesError.targetNotFound(
                    "Expected \(expectedKind.rawValue) artifact, got \(first.kind.rawValue)"
                )
            }
            return first
        }

        if let name = request.targetName {
            let matches = snapshot.artifacts.filter { item in
                let agentMatches = request.agent == nil || item.agent == request.agent
                let kindMatches = expectedKind == nil || item.kind == expectedKind
                let nameMatches =
                    item.name == name
                    || item.id.rawValue == name
                    || item.location.path == name
                return agentMatches && kindMatches && nameMatches
            }
            if let match = matches.first {
                return match
            }
        }

        throw BentoFixesError.targetNotFound(
            "Target artifact '\(request.targetName ?? "")' not found in snapshot"
        )
    }

    static func skillDirectoryURL(for artifact: Artifact) -> URL {
        let url = URL(fileURLWithPath: artifact.location.path)
        if url.lastPathComponent.lowercased() == "skill.md" {
            return url.deletingLastPathComponent()
        }
        return url
    }

    private func resolveClaudeProjectRoot(forMCPFile fileURL: URL, snapshot: Snapshot) -> URL {
        let parent = fileURL.deletingLastPathComponent()
        if parent.lastPathComponent == ".claude" {
            return parent.deletingLastPathComponent()
        }
        if let repoPath = inferRepoPath(for: fileURL.path, snapshot: snapshot) {
            return URL(fileURLWithPath: repoPath, isDirectory: true)
        }
        return parent
    }

    private func inferRepoPath(for path: String, snapshot: Snapshot) -> String? {
        let stdPath = BackupManager.normalizeLexicalPath(path)
        let matching = snapshot.repos.filter { repo in
            stdPath == repo.path
                || stdPath.hasPrefix(repo.path + "/")
                || stdPath == repo.realPath
                || stdPath.hasPrefix(repo.realPath + "/")
        }
        return matching.max(by: { $0.path.count < $1.path.count })?.path
    }

    private func readRequiredUTF8File(at url: URL) throws -> (text: String, sha256: String) {
        let data: Data
        do {
            data = try fileSystem.contents(at: url)
        } catch {
            throw BentoFixesError.targetNotFound("Cannot read '\(url.path)': \(error)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw BentoFixesError.malformedConfiguration(
                path: url.path,
                details: "File is not valid UTF-8"
            )
        }
        return (text, ContentHasher.sha256Hex(data))
    }

    private func readOptionalUTF8File(at url: URL) throws -> (text: String?, sha256: String?) {
        guard DirectoryHasher.lstatExists(atPath: url.path) else {
            return (nil, nil)
        }
        let (text, hash) = try readRequiredUTF8File(at: url)
        return (text, hash)
    }

    private func encodePersistedPlanJSON(_ plan: FixPlan) -> String {
        let summary = PersistedFixPlanSummary(from: plan)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(summary) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Stash Index Helpers

    private func loadStashIndex() throws -> (index: DisabledStashIndex, oldHash: String?) {
        guard DirectoryHasher.lstatExists(atPath: stashIndexURL.path) else {
            return (DisabledStashIndex(), nil)
        }
        let data = try Data(contentsOf: stashIndexURL)
        let hash = ContentHasher.sha256Hex(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DisabledStashIndex.self, from: data)
        return (decoded, hash)
    }

    private func encodeStashIndex(_ index: DisabledStashIndex) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(index)
    }

    private func planStashUpsert(record: DisabledStashRecord) throws -> [FileOp] {
        var (index, oldHash) = try loadStashIndex()
        index.entries.removeAll { existing in
            existing.kind == record.kind
                && existing.agent == record.agent
                && existing.name == record.name
                && existing.originalPath == record.originalPath
                && existing.keyPath == record.keyPath
        }
        index.entries.append(record)
        let encoded = try encodeStashIndex(index)
        let disabledDir = stashIndexURL.deletingLastPathComponent()
        var ops: [FileOp] = []
        if !DirectoryHasher.lstatExists(atPath: disabledDir.path) {
            ops.append(.mkdir(path: disabledDir.path))
        }
        ops.append(
            .writeFile(
                path: stashIndexURL.path,
                newBytes: encoded,
                expectedOldHash: oldHash
            )
        )
        return ops
    }

    private func planStashRemove(recordID: String) throws -> [FileOp] {
        var (index, oldHash) = try loadStashIndex()
        index.entries.removeAll { $0.id == recordID }
        let encoded = try encodeStashIndex(index)
        return [
            .writeFile(
                path: stashIndexURL.path,
                newBytes: encoded,
                expectedOldHash: oldHash
            )
        ]
    }

    private func findStashedRecord(
        kind: DisabledStashRecord.EntryKind,
        agent: AgentID,
        name: String,
        repoPath: String?
    ) throws -> DisabledStashRecord? {
        let (index, _) = try loadStashIndex()
        let matches = index.entries.filter { entry in
            guard entry.kind == kind && entry.agent == agent && entry.name == name else {
                return false
            }
            if let repoPath {
                return entry.repoPath == repoPath || entry.originalPath.hasPrefix(repoPath + "/")
            }
            return true
        }
        return matches.last
    }

    // MARK: - Markdown Duplicate Rules Replacement Helpers

    private static func relativePath(fromDirectory baseDir: URL, toFile targetFile: URL) -> String {
        let baseComps = BackupManager.normalizeLexicalPath(baseDir.path)
            .split(separator: "/")
            .map(String.init)
        let targetComps = BackupManager.normalizeLexicalPath(targetFile.path)
            .split(separator: "/")
            .map(String.init)

        var common = 0
        while common < baseComps.count && common < targetComps.count && baseComps[common] == targetComps[common] {
            common += 1
        }

        let upCount = baseComps.count - common
        let ups = Array(repeating: "..", count: upCount)
        let downs = Array(targetComps[common...])
        let rel = (ups + downs).joined(separator: "/")
        return rel.isEmpty ? targetFile.lastPathComponent : rel
    }

    private static func replaceDuplicateRuleLines(
        sourceText: String,
        targetText: String,
        importDirective: String,
        sourcePath: String,
        targetPath: String
    ) throws -> String {
        let lineEnding = sourceText.contains("\r\n") ? "\r\n" : "\n"
        let hasTrailingNewline = sourceText.hasSuffix("\n")

        let (frontmatterPrefix, sourceBody) = splitOptionalYAMLFrontmatter(sourceText)
        let (_, targetBody) = splitOptionalYAMLFrontmatter(targetText)

        let targetNormalizedSet = extractNormalizedRuleLines(from: targetBody)
        guard !targetNormalizedSet.isEmpty else {
            throw BentoFixesError.noDuplicateRulesFound(sourcePath: sourcePath, targetPath: targetPath)
        }

        var rawLines = sourceBody.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if hasTrailingNewline && rawLines.last == "" {
            rawLines.removeLast()
        }

        var keptLines: [String] = []
        var inCodeFence = false
        var insertedDirective = rawLines.contains {
            $0.trimmingCharacters(in: .whitespaces) == importDirective
        }
        var removedCount = 0

        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inCodeFence.toggle()
                keptLines.append(line)
                continue
            }
            if inCodeFence || trimmed.isEmpty || trimmed.hasPrefix("#") {
                keptLines.append(line)
                continue
            }

            if let norm = normalizeRuleLine(trimmed), targetNormalizedSet.contains(norm) {
                removedCount += 1
                if !insertedDirective {
                    if let last = keptLines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                        keptLines.append("")
                    }
                    keptLines.append(importDirective)
                    keptLines.append("")
                    insertedDirective = true
                }
                continue
            }

            keptLines.append(line)
        }

        guard removedCount > 0 else {
            throw BentoFixesError.noDuplicateRulesFound(sourcePath: sourcePath, targetPath: targetPath)
        }

        // Collapse runs of >1 consecutive blank lines.
        var collapsed: [String] = []
        for line in keptLines {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank && (collapsed.last?.trimmingCharacters(in: .whitespaces).isEmpty == true) {
                continue
            }
            collapsed.append(line)
        }
        while collapsed.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            collapsed.removeLast()
        }

        let bodyJoined = collapsed.joined(separator: lineEnding) + (hasTrailingNewline ? lineEnding : "")
        return frontmatterPrefix + bodyJoined
    }

    private static func splitOptionalYAMLFrontmatter(_ text: String) -> (prefix: String, body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else {
            return ("", text)
        }
        let lines = normalized.components(separatedBy: "\n")
        for idx in 1..<lines.count {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." {
                let fmText = lines[0...idx].joined(separator: "\n") + "\n"
                let rest = lines[(idx + 1)...].joined(separator: "\n")
                return (fmText, rest)
            }
        }
        return ("", text)
    }

    private static func extractNormalizedRuleLines(from markdown: String) -> Set<String> {
        var result: Set<String> = []
        var inCodeFence = false
        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inCodeFence.toggle()
                continue
            }
            if inCodeFence || trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            if let norm = normalizeRuleLine(trimmed) {
                result.insert(norm)
            }
        }
        return result
    }

    private static func normalizeRuleLine(_ trimmed: String) -> String? {
        var s = trimmed
        for bullet in ["- ", "* ", "+ ", "> "] where s.hasPrefix(bullet) {
            s = String(s.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        if let dotIdx = s.firstIndex(of: "."),
            s[..<dotIdx].allSatisfy(\.isNumber),
            s.index(after: dotIdx) < s.endIndex,
            s[s.index(after: dotIdx)].isWhitespace
        {
            s = String(s[s.index(after: dotIdx)...]).trimmingCharacters(in: .whitespaces)
        }

        s =
            s
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .lowercased()

        let collapsed = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count >= 4 ? collapsed : nil
    }
}
