import BentoAdapters
import BentoCore
import BentoLogIngest
import BentoScanner
import BentoStore
import BentoTestSupport
import BentoTokenizer
import Foundation
import Testing

struct UsageJoinTests {
    @Test(
        "UsageJoinEngine flags 0-call MCP server, skill, and subagent over 30 days in >=5-session repo, ranks by cost*unused, and skips <5-session repo"
    )
    func usageJoinFlagsUnusedInActiveRepoRanksByCostTimesUnusedAndSkipsLowSessionRepo() async throws {
        let fixture = try FixtureHome(scenario: "usage-join")
        let now = Date(timeIntervalSince1970: 1_793_404_800)  // 2026-10-31T00:00:00Z
        let env = fixture.makeEnvironment(now: now)
        let store = try BentoStore.inMemory()
        let workspace = Workspace(environment: env, store: store)

        let snapshot = try await workspace.scanFull()
        let targets = try await workspace.logIngestTargets()
        _ = try await LogIngestor(fileSystem: env.fileSystem, store: store).ingest(targets: targets)

        let tokenizer = try AgentTokenizerRegistry()
        let appRepoURL = fixture.url.appendingPathComponent("repos/app").standardizedFileURL
        let protoRepoURL = fixture.url.appendingPathComponent("repos/new-prototype").standardizedFileURL

        // 1. 30-day window on repos/app (6 sessions >= 5 minimum)
        let since30d = now.addingTimeInterval(-30.0 * 86_400.0)
        let appSummary30d = try store.usageSummary(
            since: since30d,
            until: now,
            agent: .claudeCode,
            repoPath: appRepoURL.path
        )
        #expect(appSummary30d.sessionCount == 6)

        let (appArtifacts, appResolution) = try await workspace.resolvedContext(
            for: .claudeCode,
            folder: appRepoURL
        )
        let appMeasuredMedian = try store.measuredFirstTurnMedianInput(
            agent: .claudeCode,
            repoPath: appRepoURL.path,
            since: since30d,
            until: now
        )
        #expect(appMeasuredMedian == 18_590)

        let appBudget = try await workspace.budget(
            for: .claudeCode,
            folder: appRepoURL,
            tokenizer: tokenizer,
            measuredFirstTurnInput: appMeasuredMedian
        )
        #expect(appBudget.measuredFirstTurnInput == 18_590)

        let joinEngine = UsageJoinEngine()
        let report30d = joinEngine.join(
            repoPath: appRepoURL.path,
            windowDays: 30,
            since: since30d,
            until: now,
            minimumSessions: 5,
            inputs: [
                UsageJoinAgentInput(
                    agent: .claudeCode,
                    artifacts: appArtifacts,
                    resolution: appResolution,
                    budget: appBudget,
                    fixSupport: workspace.fixSupport(for: .claudeCode),
                    usage: appSummary30d.byAgent.first { $0.agent == .claudeCode }
                )
            ]
        )

        // Expected 7 active invokable items:
        // unused-analytics (MCP, 0 calls), active-docs (MCP, 4 calls incl. active_docs underscore),
        // unused-auditor (subagent, 0 calls), used-reviewer (subagent, 2 calls),
        // unused-skill (skill, 0 calls), used-skill (skill, 2 calls),
        // deploy-check (command, 0 pre-prompt tokens, 0 calls).
        #expect(report30d.items.count == 7)

        // Verify "cost × unused" ranking: unused-analytics MCP server (1200 * 6 = 7200) must be #1!
        let top1 = try #require(report30d.items.first)
        #expect(top1.name == "unused-analytics")
        #expect(top1.kind == .mcpServer)
        #expect(top1.invocationCount == 0)
        #expect(top1.tokensCostPerSession == 1_200)
        #expect(top1.costTimesUnusedScore == 7_200)

        // Top 3 items are the 3 unused pre-prompt-cost-bearing items ordered by costTimesUnusedScore descending
        let topThreeNames = Array(report30d.items.prefix(3).map(\.name))
        #expect(topThreeNames == ["unused-analytics", "unused-auditor", "unused-skill"])
        #expect(report30d.items[0].costTimesUnusedScore > report30d.items[1].costTimesUnusedScore)
        #expect(report30d.items[1].costTimesUnusedScore > report30d.items[2].costTimesUnusedScore)

        // Active items must record exact invocation counts (including active-docs matching active_docs)
        let activeDocsJoin = try #require(report30d.items.first { $0.name == "active-docs" })
        #expect(activeDocsJoin.invocationCount == 4)
        #expect(activeDocsJoin.costTimesUnusedScore == 0)
        #expect(activeDocsJoin.lastUsedAt != nil)

        let usedSkillJoin = try #require(report30d.items.first { $0.name == "used-skill" })
        #expect(usedSkillJoin.invocationCount == 2)
        #expect(usedSkillJoin.costTimesUnusedScore == 0)

        let usedReviewerJoin = try #require(report30d.items.first { $0.name == "used-reviewer" })
        #expect(usedReviewerJoin.invocationCount == 2)
        #expect(usedReviewerJoin.costTimesUnusedScore == 0)

        // Unused findings: exactly 3 (unused-analytics, unused-auditor, unused-skill; NOT active-docs and NOT 0-cost command)
        #expect(report30d.unusedFindings.count == 3)
        #expect(report30d.unusedFindings.allSatisfy { $0.kind == .unused })

        let artifactsByID = Dictionary(uniqueKeysWithValues: appArtifacts.map { ($0.id, $0) })
        let flaggedNames = Set(
            report30d.unusedFindings.compactMap { finding in
                finding.artifacts.first.flatMap { artifactsByID[$0]?.name }
            }
        )
        #expect(flaggedNames == ["unused-analytics", "unused-auditor", "unused-skill"])

        let mcpFinding = try #require(
            report30d.unusedFindings.first {
                $0.artifacts.first.flatMap { artifactsByID[$0]?.name } == "unused-analytics"
            }
        )
        #expect(mcpFinding.suggestedFixes == [.disableMCPServer])

        let skillFinding = try #require(
            report30d.unusedFindings.first {
                $0.artifacts.first.flatMap { artifactsByID[$0]?.name } == "unused-skill"
            }
        )
        #expect(skillFinding.suggestedFixes.contains(.disableSkill))

        // 2. Widening window to 90 days includes uj-app-old-0 (2026-08-22) where unused-analytics had 1 call -> no longer flagged!
        let since90d = now.addingTimeInterval(-90.0 * 86_400.0)
        let appSummary90d = try store.usageSummary(
            since: since90d,
            until: now,
            agent: .claudeCode,
            repoPath: appRepoURL.path
        )
        #expect(appSummary90d.sessionCount == 7)
        let report90d = joinEngine.join(
            repoPath: appRepoURL.path,
            windowDays: 90,
            since: since90d,
            until: now,
            minimumSessions: 5,
            inputs: [
                UsageJoinAgentInput(
                    agent: .claudeCode,
                    artifacts: appArtifacts,
                    resolution: appResolution,
                    budget: appBudget,
                    fixSupport: workspace.fixSupport(for: .claudeCode),
                    usage: appSummary90d.byAgent.first { $0.agent == .claudeCode }
                )
            ]
        )
        let flaggedNames90d = Set(
            report90d.unusedFindings.compactMap { finding in
                finding.artifacts.first.flatMap { artifactsByID[$0]?.name }
            }
        )
        #expect(!flaggedNames90d.contains("unused-analytics"))
        #expect(flaggedNames90d == ["unused-auditor", "unused-skill"])

        // 3. Low-session repo (repos/new-prototype has only 2 sessions < 5 minimum) -> 0 unused findings!
        let protoSummary30d = try store.usageSummary(
            since: since30d,
            until: now,
            agent: .claudeCode,
            repoPath: protoRepoURL.path
        )
        #expect(protoSummary30d.sessionCount == 2)
        let (protoArtifacts, protoResolution) = try await workspace.resolvedContext(
            for: .claudeCode,
            folder: protoRepoURL
        )
        let protoBudget = try await workspace.budget(
            for: .claudeCode,
            folder: protoRepoURL,
            tokenizer: tokenizer
        )
        let protoReport = joinEngine.join(
            repoPath: protoRepoURL.path,
            windowDays: 30,
            since: since30d,
            until: now,
            minimumSessions: 5,
            inputs: [
                UsageJoinAgentInput(
                    agent: .claudeCode,
                    artifacts: protoArtifacts,
                    resolution: protoResolution,
                    budget: protoBudget,
                    fixSupport: workspace.fixSupport(for: .claudeCode),
                    usage: protoSummary30d.byAgent.first { $0.agent == .claudeCode }
                )
            ]
        )
        #expect(!protoReport.items.isEmpty)
        #expect(protoReport.unusedFindings.isEmpty)

        // 4. BentoStore finding persistence round-trip preserves dismissed state across re-saves
        try store.saveFindings(
            report30d.unusedFindings,
            snapshotID: snapshot.id,
            replacingKind: .unused
        )
        let activeFindings = try store.fetchFindings(snapshotID: snapshot.id, kind: .unused)
        #expect(activeFindings.count == 3)

        try store.setFindingDismissed(id: mcpFinding.id, snapshotID: snapshot.id, dismissed: true)
        let afterDismiss = try store.fetchFindings(snapshotID: snapshot.id, kind: .unused)
        #expect(afterDismiss.count == 2)
        #expect(!afterDismiss.contains { $0.id == mcpFinding.id })

        // Re-saving the same findings must keep mcpFinding dismissed!
        try store.saveFindings(
            report30d.unusedFindings,
            snapshotID: snapshot.id,
            replacingKind: .unused
        )
        let afterResave = try store.fetchFindings(snapshotID: snapshot.id, kind: .unused)
        #expect(afterResave.count == 2)
        let allIncludingDismissed = try store.fetchFindings(
            snapshotID: snapshot.id,
            kind: .unused,
            includeDismissed: true
        )
        #expect(allIncludingDismissed.count == 3)
    }
}
