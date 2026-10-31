import BentoCore
import SwiftUI

/// Right-hand `NavigationSplitView` Inspector column displaying rich metadata for the active selection (`PLAN.md` §6.7).
struct InspectorView: View {
    let model: BentoAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Inspector")
                    .font(.headline)

                Divider()

                switch model.inspectorSelection {
                case .none:
                    Text(
                        "Select an artifact, budget item, hygiene finding, usage row, or fix journal entry to inspect its details."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                case .artifact(let artifactID):
                    if let artifact = model.artifact(for: artifactID) {
                        ArtifactInspectorSection(artifact: artifact, model: model)
                    } else {
                        Text("Artifact is no longer present in the current snapshot.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .budgetItem(let item, let agent):
                    BudgetItemInspectorSection(item: item, agent: agent, model: model)

                case .finding(let findingID):
                    if let finding = model.allFindings.first(where: { $0.id == findingID }) {
                        FindingInspectorSection(finding: finding, model: model)
                    } else {
                        Text("Finding was resolved or dismissed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .usageItem(let usage):
                    UsageItemInspectorSection(usage: usage, model: model)

                case .fixJournal(let fixID):
                    if let entry = model.fixHistory.first(where: { $0.id == fixID }) {
                        FixJournalInspectorSection(entry: entry, model: model)
                    } else {
                        Text("Fix journal entry not found.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
        }
    }
}

private struct ArtifactInspectorSection: View {
    let artifact: Artifact
    let model: BentoAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(artifact.name)
                .font(.subheadline.weight(.bold))

            InspectorKeyValue("Agent", artifact.agent.displayName)
            InspectorKeyValue("Kind", artifact.kind.displayName)
            InspectorKeyValue("Scope", artifact.scope.badgeTitle)
            InspectorKeyValue("Enabled", artifact.enabled ? "Yes" : "No")
            InspectorKeyValue("Load Mode", artifact.loadMode.displayLabel)
            InspectorKeyValue("Path", model.abbreviateHomePath(artifact.location.path), monospaced: true)
            if artifact.location.realPath != artifact.location.path {
                InspectorKeyValue("Real Path", model.abbreviateHomePath(artifact.location.realPath), monospaced: true)
            }
            InspectorKeyValue("SHA-256", String(artifact.contentHash.prefix(16)) + "…", monospaced: true)

            HStack(spacing: 8) {
                Button("Reveal in Finder") {
                    model.revealArtifactInFinder(artifact)
                }
                .controlSize(.small)

                Button("Open in editor") {
                    model.openArtifactInEditor(artifact)
                }
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
    }
}

private struct BudgetItemInspectorSection: View {
    let item: BudgetItem
    let agent: AgentID
    let model: BentoAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.label)
                .font(.subheadline.weight(.bold))

            InspectorKeyValue("Agent", agent.displayName)
            InspectorKeyValue("Category", item.category.displayName)
            InspectorKeyValue("Tokens", "\(item.tokens)")
            if let range = item.range {
                InspectorKeyValue("Uncertainty Range", "\(range.lowerBound)–\(range.upperBound) tokens")
            }
            InspectorKeyValue("Confidence", item.confidence.badgeTitle)
            InspectorKeyValue("Method", item.method)
            InspectorKeyValue(
                "Context Entry", item.countsTowardPrePrompt ? "Pre-prompt (always loaded)" : "Deferred / On-invoke")

            if let artifactID = item.artifactID, let artifact = model.artifact(for: artifactID) {
                Divider()
                ArtifactInspectorSection(artifact: artifact, model: model)
            }
        }
    }
}

private struct FindingInspectorSection: View {
    let finding: Finding
    let model: BentoAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(finding.kind.displayName)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(finding.severity.tintColor)

            InspectorKeyValue("Severity", finding.severity.rawValue.capitalized)
            InspectorKeyValue("Finding ID", String(finding.id.prefix(18)) + "…", monospaced: true)
            Text(finding.message)
                .font(.caption)
                .textSelection(.enabled)

            if !finding.suggestedFixes.isEmpty {
                Divider()
                Text("Suggested Reversible Fixes")
                    .font(.caption.weight(.semibold))
                ForEach(finding.suggestedFixes, id: \.self) { fixKind in
                    Button(fixKind.displayName) {
                        do {
                            try model.openSuggestedFix(fixKind, for: finding)
                        } catch {
                            model.lastErrorMessage = error.localizedDescription
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

private struct UsageItemInspectorSection: View {
    let usage: ArtifactUsageJoin
    let model: BentoAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(usage.name)
                .font(.subheadline.weight(.bold))

            InspectorKeyValue("Agent", usage.agent.displayName)
            InspectorKeyValue("Kind", usage.kind.displayName)
            InspectorKeyValue("Scope", usage.scope.badgeTitle)
            InspectorKeyValue("Pre-Prompt Tokens/Session", "\(usage.tokensCostPerSession)")
            InspectorKeyValue("Deferred Tokens", "\(usage.deferredTokensEstimate)")
            InspectorKeyValue("Invocations (\(usage.windowDays)d)", "\(usage.invocationCount)")
            InspectorKeyValue("Sessions in Window", "\(usage.sessionCountInWindow)")
            InspectorKeyValue("Cost × Unused Score", "\(usage.costTimesUnusedScore)")
            InspectorKeyValue("Path", model.abbreviateHomePath(usage.path), monospaced: true)
        }
    }
}

private struct FixJournalInspectorSection: View {
    let entry: FixJournalEntry
    let model: BentoAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.kind.displayName)
                .font(.subheadline.weight(.bold))

            InspectorKeyValue("Fix ID", entry.id, monospaced: true)
            InspectorKeyValue("Status", entry.status.rawValue)
            InspectorKeyValue("Created", entry.createdAt.formatted(date: .abbreviated, time: .standard))
            if let applied = entry.appliedAt {
                InspectorKeyValue("Applied", applied.formatted(date: .abbreviated, time: .standard))
            }
            if let undone = entry.undoneAt {
                InspectorKeyValue("Undone", undone.formatted(date: .abbreviated, time: .standard))
            }
            InspectorKeyValue("Backup Dir", model.abbreviateHomePath(entry.backupDir), monospaced: true)
        }
    }
}

private struct InspectorKeyValue: View {
    let key: String
    let value: String
    var monospaced: Bool = false

    init(_ key: String, _ value: String, monospaced: Bool = false) {
        self.key = key
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
        }
    }
}
