import BentoAdapters
import BentoCore
import BentoHygiene
import BentoLogIngest
import BentoParsing
import BentoScanner
import BentoStore
import BentoTestSupport
import BentoTokenizer
import CryptoKit
import Foundation
import Testing

struct BentoHygieneTests {
    private static func defaultFixSupports() -> [AgentID: FixSupport] {
        var map: [AgentID: FixSupport] = [:]
        for adapter in AgentAdapters.all {
            map[type(of: adapter).id] = adapter.fixSupport()
        }
        return map
    }

    @Test("Bundled conflicts.yaml matches root Resources/hygiene/conflicts.yaml byte-for-byte with >= 15 rules")
    func conflictCatalogMatchesBundledResourceAndHasAtLeastFifteenPairs() throws {
        let repoRoot = FixtureHome.repositoryRoot()
        let rootURL = repoRoot.appendingPathComponent("Resources/hygiene/conflicts.yaml")
        let bundledURL = repoRoot.appendingPathComponent(
            "Sources/BentoHygiene/Resources/hygiene/conflicts.yaml"
        )

        let rootBytes = try Data(contentsOf: rootURL)
        let bundledBytes = try Data(contentsOf: bundledURL)
        #expect(rootBytes == bundledBytes, "Resources/hygiene/conflicts.yaml must match bundled copy")

        let catalog = try ConflictCatalog.loadDefault()
        #expect(catalog.schemaVersion == 1)
        #expect(catalog.rules.count >= 15)

        let uniqueIDs = Set(catalog.rules.map(\.id))
        #expect(uniqueIDs.count == catalog.rules.count, "Conflict rule IDs must be unique")
    }

    @Test("MinHashLSH produces deterministic 128-perm signatures and identifies near-duplicates at Jaccard >= 0.80")
    func minHashLSHDeterminismAndNearDuplicateThreshold() throws {
        let rawA =
            "- Always validate incoming webhook payloads against strict JSON schemas before enqueueing background jobs for workers."
        let rawB =
            "- Always validate incoming webhook payloads against strict JSON schemas before enqueueing background tasks for workers."
        let rawDifferent =
            "- Prefer immutable value types and explicit dependency injection across Swift concurrency boundaries."

        let normA = MarkdownRuleSplitter.normalize(rawA)
        let normB = MarkdownRuleSplitter.normalize(rawB)
        let normDiff = MarkdownRuleSplitter.normalize(rawDifferent)

        let shinglesA = MinHashLSH.shingles(for: normA, wordCount: 5)
        let shinglesB = MinHashLSH.shingles(for: normB, wordCount: 5)
        let shinglesDiff = MinHashLSH.shingles(for: normDiff, wordCount: 5)

        #expect(!shinglesA.isEmpty)
        let jaccardAB = MinHashLSH.jaccard(shinglesA, shinglesB)
        let jaccardADiff = MinHashLSH.jaccard(shinglesA, shinglesDiff)

        // Note: 15 words -> 11 5-grams; changing word #12 ("jobs" vs "tasks") alters 4 5-grams out of 11 -> 7 / 15 < 0.8.
        // Verify exact mathematical Jaccard and test a >= 0.80 pair as well!
        #expect(jaccardADiff == 0.0)
        #expect(jaccardAB > 0.4)

        let longA = MarkdownRuleSplitter.normalize(
            "- Always verify database migration rollback scripts in staging environments before promoting production container images to regional clusters across every deployment pipeline."
        )
        let longB = MarkdownRuleSplitter.normalize(
            "- Always verify database migration rollback scripts in staging environments before promoting production container images to regional clusters across every deployment pipelines."
        )
        let longShinglesA = MinHashLSH.shingles(for: longA, wordCount: 5)
        let longShinglesB = MinHashLSH.shingles(for: longB, wordCount: 5)
        let longJaccard = MinHashLSH.jaccard(longShinglesA, longShinglesB)
        #expect(longJaccard >= 0.80, "Expected Jaccard >= 0.80, got \(longJaccard)")

        let lsh1 = MinHashLSH(permutations: 128, bands: 32)
        let lsh2 = MinHashLSH(permutations: 128, bands: 32)
        let sigA1 = lsh1.signature(for: longShinglesA)
        let sigA2 = lsh2.signature(for: longShinglesA)
        #expect(sigA1.count == 128)
        #expect(sigA1 == sigA2, "MinHash signatures must be deterministic across instances")

        let sigB = lsh1.signature(for: longShinglesB)
        let sigDiff = lsh1.signature(for: shinglesDiff)
        let candidates = lsh1.candidatePairs(for: [sigA1, sigB, sigDiff])
        #expect(candidates.contains { ($0.0 == 0 && $0.1 == 1) || ($0.0 == 1 && $0.1 == 0) })
    }

    @Test(
        "Block-level >= 70% overlap suggests @AGENTS.md import only for import-capable agents and consolidates identical skills"
    )
    func blockImportSuggestionAndSkillConsolidation() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-hygiene-block-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let repoURL = tempHome.appendingPathComponent("repos/sample", isDirectory: true)
        let cursorRulesDir = repoURL.appendingPathComponent(".cursor/rules", isDirectory: true)
        let claudeSkillDir = repoURL.appendingPathComponent(".claude/skills/lint-helper", isDirectory: true)
        let codexSkillDir = repoURL.appendingPathComponent(".agents/skills/lint-helper", isDirectory: true)

        try FileManager.default.createDirectory(at: cursorRulesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeSkillDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexSkillDir, withIntermediateDirectories: true)

        let agentsContent = """
            # Sample Shared Rules

            - Validate all incoming HTTP payloads with strict schema decoders at the boundary.
            - Keep database transactions short and never perform network calls inside a transaction.
            - Always verify database migration rollback scripts in staging environments before promoting production container images to regional clusters across every deployment pipeline.
            - Emit structured JSON logs with correlation identifiers on every request handler.
            """
        let claudeContent = """
            # Claude Rules

            - Validate all incoming HTTP payloads with strict schema decoders at the boundary.
            - Keep database transactions short and never perform network calls inside a transaction.
            - Always verify database migration rollback scripts in staging environments before promoting production container images to regional clusters across every deployment pipelines.
            - Summarize multi-file plans before editing core persistence modules.
            """
        let cursorContent = """
            ---
            description: Mirror rules
            alwaysApply: true
            ---

            - Validate all incoming HTTP payloads with strict schema decoders at the boundary.
            - Keep database transactions short and never perform network calls inside a transaction.
            """

        try Data(agentsContent.utf8).write(to: repoURL.appendingPathComponent("AGENTS.md"))
        try Data(claudeContent.utf8).write(to: repoURL.appendingPathComponent("CLAUDE.md"))
        try Data(cursorContent.utf8).write(to: cursorRulesDir.appendingPathComponent("mirror.mdc"))

        let identicalSkill = """
            ---
            name: lint-helper
            description: Run repository linters cleanly.
            ---
            # Lint Helper

            1. Run strict lint checks.
            """
        try Data(identicalSkill.utf8).write(to: claudeSkillDir.appendingPathComponent("SKILL.md"))
        try Data(identicalSkill.utf8).write(to: codexSkillDir.appendingPathComponent("SKILL.md"))

        let env = AgentEnvironment(
            home: tempHome,
            env: ["BENTO_SYSTEM_ROOT": tempHome.path],
            fileSystem: LocalReadOnlyFileSystem(),
            now: { Date(timeIntervalSince1970: 1_761_800_000) }
        )
        let workspace = Workspace(
            environment: env,
            repoDiscoveryOptions: RepoDiscoveryOptions(manualPaths: [repoURL])
        )
        let snapshot = try await workspace.scanFull()

        let findings = try HygieneEngine().audit(
            snapshot: snapshot,
            fixSupports: Self.defaultFixSupports(),
            fileSystem: env.fileSystem,
            tokenizer: try AgentTokenizerRegistry()
        )

        // 1. Near-duplicate rule unit between AGENTS.md:5 and CLAUDE.md:5
        let nearDupes = findings.filter { $0.kind == .nearDuplicate && $0.suggestedFixes.isEmpty }
        #expect(nearDupes.count == 1)

        // 2. Block-level @AGENTS.md suggestion for CLAUDE.md (3/4 = 75% >= 70%, Claude supports @imports)
        let importSuggestions = findings.filter {
            $0.suggestedFixes.contains(.replaceDuplicateRulesWithImport)
        }
        #expect(importSuggestions.count == 1)
        let importFinding = try #require(importSuggestions.first)
        #expect(importFinding.spans.count == 2)
        #expect(importFinding.spans[0].path.hasSuffix("/CLAUDE.md"))
        #expect(importFinding.spans[1].path.hasSuffix("/AGENTS.md"))

        // Cursor mirror.mdc has 100% overlap with AGENTS.md, but Cursor does NOT support @imports.
        let cursorImportSuggestions = importSuggestions.filter { finding in
            finding.spans.contains { $0.path.hasSuffix("/mirror.mdc") }
        }
        #expect(cursorImportSuggestions.isEmpty)

        // 3. Identical non-symlinked skills across .claude/skills and .agents/skills suggest symlink consolidation.
        let skillConsolidations = findings.filter {
            $0.suggestedFixes.contains(.consolidateSkillsViaSymlink)
        }
        #expect(skillConsolidations.count == 1)
        #expect(skillConsolidations.first?.kind == .exactDuplicate)
        #expect(skillConsolidations.first?.spans.count == 2)
    }

    @Test("Conflict engine detects opposing directives with both spans while respecting modality and language scopes")
    func conflictEngineDetectsOpposingDirectivesWithoutFalsePositives() throws {
        let engine = HygieneEngine()

        func makeRuleArtifact(
            agent: AgentID,
            path: String,
            content: String
        ) -> Artifact {
            let loc = SourceLocation(path: path, realPath: path)
            let id = ArtifactID(agent: agent, kind: .rules, scope: .project, path: path)
            return Artifact(
                id: id,
                agent: agent,
                kind: .rules,
                scope: .project,
                name: URL(fileURLWithPath: path).lastPathComponent,
                location: loc,
                contentHash: ContentHasher.sha256NormalizedText(content),
                enabled: true,
                loadMode: .always,
                payload: .rules(
                    RulesDoc(
                        content: content,
                        byteCount: content.utf8.count,
                        characterCount: content.count
                    )
                )
            )
        }

        let repoPath = "/virtual/home/repos/conflict-lab"
        let repo = DiscoveredRepo(path: repoPath, realPath: repoPath, displayName: "conflict-lab", sources: [.manual])

        // True opposing pairs across files
        let fileA = makeRuleArtifact(
            agent: .claudeCode,
            path: "\(repoPath)/CLAUDE.md",
            content: """
                # File A

                - Use tabs for indentation.
                - Use single quotes for all strings.
                - Always use semicolons at the end of statements.
                - Always commit changes automatically after completing a task.
                - Always run unit tests before opening a pull request.
                - Keep maximum line length at 80 columns.
                - Target Node.js 18 in production services.
                """
        )
        let fileB = makeRuleArtifact(
            agent: .gemini,
            path: "\(repoPath)/GEMINI.md",
            content: """
                # File B

                - Use spaces for indentation.
                - Prefer double quotes for strings.
                - Omit semicolons across modules.
                - Never commit changes; leave git commits to the user.
                - Don't run unit tests automatically.
                - Keep maximum line length at 120 columns.
                - Require Node.js 22 runtime.
                """
        )

        let findings = try engine.audit(
            artifacts: [fileA, fileB],
            repos: [repo],
            homePath: "/virtual/home"
        )
        let conflicts = findings.filter { $0.kind == .conflict }
        #expect(conflicts.count == 7)
        for conflict in conflicts {
            #expect(conflict.spans.count == 2, "Every conflict must carry both opposing spans")
            #expect(conflict.spans[0].lineRange != nil)
            #expect(conflict.spans[1].lineRange != nil)
        }

        // Non-conflicting modality & language-scoped cases -> 0 conflicts!
        let safeA = makeRuleArtifact(
            agent: .claudeCode,
            path: "\(repoPath)/CLAUDE.md",
            content: """
                # Safe A

                - Use pnpm instead of npm for JavaScript package management.
                - Use 4 spaces for indentation in Swift files.
                - Never commit secrets or API keys.
                """
        )
        let safeB = makeRuleArtifact(
            agent: .codex,
            path: "\(repoPath)/AGENTS.md",
            content: """
                # Safe B

                - Prefer pnpm for JavaScript package management.
                - Use 2 spaces for indentation in TypeScript files.
                - Always commit each task on a dedicated feature branch.
                """
        )

        let safeFindings = try engine.audit(
            artifacts: [safeA, safeB],
            repos: [repo],
            homePath: "/virtual/home"
        )
        let safeConflicts = safeFindings.filter { $0.kind == .conflict }
        #expect(safeConflicts.isEmpty, "Expected 0 false conflicts, got: \(safeConflicts.map(\.message))")
    }

    @Test("windsurf-limits flags ONLY the over-limit files (global_rules.md > 6k and over-12k.md > 12k)")
    func windsurfLimitsFlagsOnlyOverLimitFiles() async throws {
        let fixture = try FixtureHome(scenario: "windsurf-limits")
        let env = fixture.makeEnvironment()
        let repoURL = fixture.url.appendingPathComponent("repos/cascade-app").standardizedFileURL
        let workspace = Workspace(
            environment: env,
            repoDiscoveryOptions: RepoDiscoveryOptions(manualPaths: [repoURL])
        )
        let snapshot = try await workspace.scanFull()

        let findings = try HygieneEngine().audit(
            snapshot: snapshot,
            fixSupports: Self.defaultFixSupports(),
            fileSystem: env.fileSystem,
            tokenizer: try AgentTokenizerRegistry()
        )

        #expect(findings.count == 2, "Expected only the 2 over-limit Windsurf files, got: \(findings.map(\.message))")
        #expect(findings.allSatisfy { $0.kind == .sizeLimit })

        let flaggedPaths = Set(findings.flatMap { $0.spans.map { URL(fileURLWithPath: $0.path).lastPathComponent } })
        #expect(flaggedPaths == ["global_rules.md", "over-12k.md"])
        #expect(!flaggedPaths.contains("under-6k.md"))
        #expect(!flaggedPaths.contains("under-12k.md"))
    }

    @Test(
        "Detects Codex project_doc_max_bytes truncation, large always-on token limits, broken @imports, and invalid configs"
    )
    func codexTruncationTokenThresholdBrokenImportsAndInvalidConfig() async throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-hygiene-limits-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let codexDir = tempHome.appendingPathComponent(".codex", isDirectory: true)
        let claudeDir = tempHome.appendingPathComponent(".claude", isDirectory: true)
        let repoURL = tempHome.appendingPathComponent("repos/app", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)

        // 1. Codex config with small project_doc_max_bytes = 40 so AGENTS.md is truncated.
        let codexConfig = """
            model = "gpt-5-codex"
            project_doc_max_bytes = 40
            """
        try Data(codexConfig.utf8).write(to: codexDir.appendingPathComponent("config.toml"))
        let agentsDoc = """
            # Oversized Agents File For Byte Cap

            - Keep domain models free of persistence framework imports across every module in this workspace.
            """
        try Data(agentsDoc.utf8).write(to: repoURL.appendingPathComponent("AGENTS.md"))

        // 2. Claude CLAUDE.md with a broken @import
        let claudeDoc = """
            # Claude Rules

            @./does-not-exist.md
            """
        try Data(claudeDoc.utf8).write(to: repoURL.appendingPathComponent("CLAUDE.md"))

        // 3. Malformed ~/.claude/settings.json
        try Data("{ invalid json ".utf8).write(to: claudeDir.appendingPathComponent("settings.json"))

        let env = AgentEnvironment(
            home: tempHome,
            env: ["BENTO_SYSTEM_ROOT": tempHome.path],
            fileSystem: LocalReadOnlyFileSystem(),
            now: { Date(timeIntervalSince1970: 1_761_800_000) }
        )
        let workspace = Workspace(
            environment: env,
            repoDiscoveryOptions: RepoDiscoveryOptions(manualPaths: [repoURL])
        )
        let snapshot = try await workspace.scanFull()

        let config = HygieneConfig(maxAlwaysOnRuleTokens: 15)
        let findings = try HygieneEngine(config: config).audit(
            snapshot: snapshot,
            fixSupports: Self.defaultFixSupports(),
            fileSystem: env.fileSystem,
            tokenizer: try AgentTokenizerRegistry()
        )

        #expect(findings.contains { $0.kind == .sizeLimit && $0.message.contains("project_doc_max_bytes") })
        #expect(findings.contains { $0.kind == .sizeLimit && $0.message.contains("tokens") })
        #expect(findings.contains { $0.kind == .brokenImport && $0.severity == .error })
        #expect(findings.contains { $0.kind == .invalidConfig && $0.severity == .error })
    }

    @Test("Clean multi-agent fixture yields zero hygiene false positives")
    func cleanFixtureHasZeroFalsePositives() async throws {
        let fixture = try FixtureHome(scenario: "clean")
        let env = fixture.makeEnvironment()
        let workspace = Workspace(environment: env)
        let snapshot = try await workspace.scanFull()

        #expect(snapshot.repos.count == 1)
        #expect(snapshot.repos.first?.displayName == "clean-app")
        for agent in AgentID.allCases {
            #expect(snapshot.detections[agent]?.isDetected == true)
        }

        let findings = try HygieneEngine().audit(
            snapshot: snapshot,
            fixSupports: Self.defaultFixSupports(),
            fileSystem: env.fileSystem,
            tokenizer: try AgentTokenizerRegistry()
        )
        #expect(findings.isEmpty, "Expected 0 false positives on clean fixture, got: \(findings.map(\.message))")
    }

    @Test("Polyglot findings match golden with exact count/spans and pass read-only proof on chmod a-w copy")
    func polyglotFindingsGoldenAndReadOnlyProof() async throws {
        let fixture = try FixtureHome(scenario: "polyglot")
        let env = fixture.makeEnvironment()
        let workspace = Workspace(environment: env)
        let snapshot = try await workspace.scanFull()
        let tokenizer = try AgentTokenizerRegistry()

        let findings = try HygieneEngine().audit(
            snapshot: snapshot,
            fixSupports: Self.defaultFixSupports(),
            fileSystem: env.fileSystem,
            tokenizer: tokenizer
        )

        // Exact expected breakdown on polyglot: 4 exactDuplicate + 2 conflict = 6 total findings.
        let exactDupes = findings.filter { $0.kind == .exactDuplicate }
        let conflicts = findings.filter { $0.kind == .conflict }
        #expect(exactDupes.count == 4)
        #expect(conflicts.count == 2)
        #expect(findings.count == 6)

        // Verify frontmatter-adjusted physical file line numbers for `.cursor/rules/style.mdc` (lines 7 and 8).
        let cursorSpans = findings.flatMap(\.spans).filter { $0.path.hasSuffix("/.cursor/rules/style.mdc") }
        let cursorLines = Set(cursorSpans.compactMap { $0.lineRange?.lowerBound })
        #expect(cursorLines == [7, 8], "Expected frontmatter-adjusted line numbers 7 and 8 in style.mdc")

        // Verify both conflict findings carry exact 2 side-by-side spans.
        for conflict in conflicts {
            #expect(conflict.spans.count == 2)
        }

        let goldenURL = FixtureHome.repositoryRoot()
            .appendingPathComponent("Tests/BentoHygieneTests/__golden__/polyglot-findings.json")
        try GoldenFile.assertMatches(findings, goldenURL: goldenURL, homeURL: fixture.url)

        // Filtering by `--agent claudeCode` preserves cross-agent findings involving Claude Code (5 of 6).
        let claudeFindings = try HygieneEngine().audit(
            snapshot: snapshot,
            fixSupports: Self.defaultFixSupports(),
            fileSystem: env.fileSystem,
            tokenizer: tokenizer,
            agentFilter: .claudeCode
        )
        #expect(claudeFindings.count == 5)

        // Read-only proof (`PLAN.md` §9): full scan + ingest + hygiene on a `chmod -R a-w` copy of `polyglot/`.
        let tempCopy = try fixture.copyToTemporaryDirectory()
        Self.setWritableRecursively(at: tempCopy, writable: false)
        defer {
            Self.setWritableRecursively(at: tempCopy, writable: true)
            try? FileManager.default.removeItem(at: tempCopy)
        }

        let beforeHash = try Self.treeHash(at: tempCopy)
        let roEnv = AgentEnvironment(
            home: tempCopy,
            env: ["BENTO_SYSTEM_ROOT": tempCopy.path],
            fileSystem: LocalReadOnlyFileSystem(),
            now: { Date(timeIntervalSince1970: 1_761_800_000) }
        )
        let store = try BentoStore.inMemory()
        let roWorkspace = Workspace(environment: roEnv, store: store)
        let roSnapshot = try await roWorkspace.scanFull()
        try store.syncDiscoveredRepos(roSnapshot.repos, seenAt: roEnv.now())
        let logTargets = try await roWorkspace.logIngestTargets()
        _ = try await LogIngestor(fileSystem: roEnv.fileSystem, store: store).ingest(targets: logTargets)
        let roFindings = try HygieneEngine().audit(
            snapshot: roSnapshot,
            fixSupports: Self.defaultFixSupports(),
            fileSystem: roEnv.fileSystem,
            tokenizer: tokenizer
        )
        try store.saveFindings(roFindings, snapshotID: roSnapshot.id)

        let afterHash = try Self.treeHash(at: tempCopy)
        #expect(beforeHash == afterHash, "Read-only polyglot tree hash must remain unchanged")
        #expect(roFindings.map(\.id) == findings.map(\.id))
    }

    @Test("Multi-worktree snapshot with 80 repos and 5,600 rule units audits in under 1 second without LSH explosion")
    func multiWorktreeScaleAuditCompletesUnderOneSecond() throws {
        let repoCount = 80
        let homePath = "/virtual/home"
        var sharedLines: [String] = []
        for idx in 1...32 {
            sharedLines.append(
                "- Shared architectural rule \(idx): validate incoming request payloads with strict typed decoders before mutating domain state in service handlers."
            )
        }

        let agentsContent =
            (["# Shared Worktree Rules", ""] + sharedLines + [
                "- Use spaces for indentation.",
                "- Always verify database migration rollback scripts in staging environments before promoting production container images to regional clusters across every deployment pipeline."
            ]).joined(separator: "\n")

        let claudeContent =
            (["# Claude Worktree Rules", ""] + sharedLines + [
                "- Use tabs for indentation.",
                "- Always verify database migration rollback scripts in staging environments before promoting production container images to regional clusters across every deployment pipelines."
            ]).joined(separator: "\n")

        let agentsHash = ContentHasher.sha256NormalizedText(agentsContent)
        let claudeHash = ContentHasher.sha256NormalizedText(claudeContent)

        var repos: [DiscoveredRepo] = []
        var artifacts: [Artifact] = []
        repos.reserveCapacity(repoCount)
        artifacts.reserveCapacity(repoCount * 2)

        for idx in 0..<repoCount {
            let repoPath = "\(homePath)/orca/worktree-\(String(format: "%02d", idx))"
            repos.append(
                DiscoveredRepo(
                    path: repoPath,
                    realPath: repoPath,
                    displayName: "worktree-\(String(format: "%02d", idx))",
                    sources: [.shallowScan]
                )
            )

            let agentsPath = "\(repoPath)/AGENTS.md"
            artifacts.append(
                Artifact(
                    id: ArtifactID(agent: .codex, kind: .rules, scope: .project, path: agentsPath),
                    agent: .codex,
                    kind: .rules,
                    scope: .project,
                    name: "AGENTS.md",
                    location: SourceLocation(path: agentsPath, realPath: agentsPath),
                    contentHash: agentsHash,
                    enabled: true,
                    loadMode: .always,
                    payload: .rules(
                        RulesDoc(
                            content: agentsContent,
                            byteCount: agentsContent.utf8.count,
                            characterCount: agentsContent.count
                        )
                    )
                )
            )

            let claudePath = "\(repoPath)/CLAUDE.md"
            artifacts.append(
                Artifact(
                    id: ArtifactID(agent: .claudeCode, kind: .rules, scope: .project, path: claudePath),
                    agent: .claudeCode,
                    kind: .rules,
                    scope: .project,
                    name: "CLAUDE.md",
                    location: SourceLocation(path: claudePath, realPath: claudePath),
                    contentHash: claudeHash,
                    enabled: true,
                    loadMode: .always,
                    payload: .rules(
                        RulesDoc(
                            content: claudeContent,
                            byteCount: claudeContent.utf8.count,
                            characterCount: claudeContent.count
                        )
                    )
                )
            )
        }

        let clock = ContinuousClock()
        var findings: [Finding] = []
        let elapsed = try clock.measure {
            findings = try HygieneEngine().audit(
                artifacts: artifacts,
                repos: repos,
                homePath: homePath,
                fixSupports: Self.defaultFixSupports()
            )
        }

        let conflicts = findings.filter { $0.kind == .conflict }
        let nearDupes = findings.filter { $0.kind == .nearDuplicate && $0.suggestedFixes.isEmpty }
        let blockImports = findings.filter { $0.suggestedFixes.contains(.replaceDuplicateRulesWithImport) }
        let exactDupes = findings.filter { $0.kind == .exactDuplicate && $0.suggestedFixes.isEmpty }

        #expect(conflicts.count == repoCount)
        #expect(nearDupes.count == repoCount)
        #expect(blockImports.count == repoCount)
        #expect(exactDupes.count == repoCount * 32)
        #expect(elapsed < .seconds(1), "Expected 80-worktree hygiene audit under 1s, took \(elapsed)")
    }

    private static func setWritableRecursively(at root: URL, writable: Bool) {
        let fm = FileManager.default
        var urls: [URL] = [root.standardizedFileURL]
        if let enumerator = fm.enumerator(at: root.standardizedFileURL, includingPropertiesForKeys: nil) {
            while let next = enumerator.nextObject() as? URL {
                urls.append(next.standardizedFileURL)
            }
        }
        for url in (writable ? urls : urls.reversed()) {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue }
            if (attrs[.type] as? FileAttributeType) == .typeSymbolicLink { continue }
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o755
            let updated = writable ? (perms | 0o200) : (perms & ~0o222)
            try? fm.setAttributes([.posixPermissions: updated], ofItemAtPath: url.path)
        }
    }

    private static func treeHash(at root: URL) throws -> String {
        let fm = FileManager.default
        let stdRoot = root.standardizedFileURL
        var relativePaths: [String] = []
        if let enumerator = fm.enumerator(at: stdRoot, includingPropertiesForKeys: [.isRegularFileKey]) {
            while let url = enumerator.nextObject() as? URL {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                if values.isRegularFile == true {
                    let full = url.standardizedFileURL.path
                    let rel = String(full.dropFirst(stdRoot.path.count))
                    relativePaths.append(rel)
                }
            }
        }
        relativePaths.sort()
        var hasher = SHA256()
        for rel in relativePaths {
            hasher.update(data: Data(rel.utf8))
            let fileURL = stdRoot.appendingPathComponent(String(rel.dropFirst()))
            let bytes = try Data(contentsOf: fileURL)
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
