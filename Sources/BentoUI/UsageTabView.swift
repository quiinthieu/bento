import BentoCore
import BentoFixes
import SwiftUI

/// Repository Detail → `Usage` tab displaying per-artifact invocations over `N` days,
/// last-used timestamp, tokens/session, and `"Cost × Unused"` sorting (`PLAN.md` §6.7).
struct UsageTabView: View {
    let model: BentoAppModel
    let repo: DiscoveredRepo

    var body: some View {
        @Bindable var bindableModel = model
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !model.selectedRepoAgent.supportsFullBudgetAndUsage {
                    ContentUnavailableView(
                        "Usage Logs Not Modeled for \(model.selectedRepoAgent.displayName)",
                        systemImage: "waveform.path.ecg",
                        description: Text(
                            "Switch to Claude Code, Codex CLI, Gemini CLI, or Copilot CLI to inspect session usage joins."
                        )
                    )
                } else {
                    HStack {
                        Text(
                            "Invokable artifacts over last \(model.unusedWindowDays) days (unused flag requires ≥ \(model.unusedMinimumSessions) sessions)"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Sort by", selection: $bindableModel.usageSortOrder) {
                            ForEach(UsageSortOrder.allCases) { order in
                                Text(order.title).tag(order)
                            }
                        }
                        .frame(width: 210)
                        .controlSize(.small)
                    }

                    UsageItemsTableView(
                        items: model.sortedRepoUsageItems,
                        showAgentColumn: false,
                        model: model
                    )
                }
            }
            .padding(16)
        }
    }
}

/// Top-level Sidebar → `Usage` view showing cross-repository session metrics and `"Cost × Unused"` ranking.
struct GlobalUsageView: View {
    let model: BentoAppModel

    var body: some View {
        @Bindable var bindableModel = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Session & Artifact Usage")
                            .font(.title2.weight(.bold))
                        Text(
                            "Local log telemetry over rolling \(model.unusedWindowDays)-day window (counts and names only; prompts never stored)"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Sort by", selection: $bindableModel.usageSortOrder) {
                        ForEach(UsageSortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                    .frame(width: 220)
                }

                if let summary = model.globalUsageSummary, !summary.byAgent.isEmpty {
                    GroupBox("Per-Agent Session Totals") {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)
                            ],
                            spacing: 12
                        ) {
                            ForEach(summary.byAgent, id: \.agent) { agentUsage in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Label(agentUsage.agent.displayName, systemImage: agentUsage.agent.symbolName)
                                            .font(.subheadline.weight(.semibold))
                                        Spacer()
                                        Text("\(agentUsage.sessionCount) sessions")
                                            .font(.caption.monospacedDigit().weight(.medium))
                                            .foregroundStyle(.secondary)
                                    }
                                    HStack(spacing: 14) {
                                        Text("Input: \(agentUsage.inputTokens)")
                                        Text("Output: \(agentUsage.outputTokens)")
                                        if let median = agentUsage.firstTurnMedianInput {
                                            Text("1st-Turn Median: \(median)")
                                        }
                                    }
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                }
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                UsageItemsTableView(
                    items: model.sortedGlobalUsageItems,
                    showAgentColumn: true,
                    model: model
                )
            }
            .padding(20)
        }
    }
}

struct UsageItemsTableView: View {
    let items: [ArtifactUsageJoin]
    let showAgentColumn: Bool
    let model: BentoAppModel

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        GroupBox("Invokable Artifacts (\(items.count))") {
            VStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                    Text("No active skills, MCP servers, subagents, or commands found in this scope.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                } else {
                    HStack(spacing: 10) {
                        Text("Artifact")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if showAgentColumn {
                            Text("Agent")
                                .frame(width: 85, alignment: .leading)
                        }
                        Text("Kind")
                            .frame(width: 85, alignment: .leading)
                        Text("Invocations")
                            .frame(width: 85, alignment: .trailing)
                        Text("Last Used")
                            .frame(width: 95, alignment: .trailing)
                        Text("Tokens/Sess")
                            .frame(width: 90, alignment: .trailing)
                        Text("Cost × Unused")
                            .frame(width: 105, alignment: .trailing)
                        Text("Fix")
                            .frame(width: 75, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    Divider()

                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { row in
                            HStack(spacing: 10) {
                                Button {
                                    model.inspectorSelection = .usageItem(row)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(row.name)
                                                .font(.subheadline.weight(.medium))
                                                .lineLimit(1)
                                            ScopeBadgeView(scope: row.scope)
                                        }
                                        Text(model.abbreviateHomePath(row.path))
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if showAgentColumn {
                                    Text(row.agent.shortDisplayName)
                                        .font(.caption)
                                        .frame(width: 85, alignment: .leading)
                                }

                                Text(row.kind.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 85, alignment: .leading)

                                Text("\(row.invocationCount)")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(row.invocationCount == 0 ? .orange : .primary)
                                    .frame(width: 85, alignment: .trailing)

                                Text(formatLastUsed(row.lastUsedAt))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 95, alignment: .trailing)

                                Text("\(row.tokensCostPerSession)")
                                    .font(.subheadline.monospacedDigit())
                                    .frame(width: 90, alignment: .trailing)

                                Text("\(row.costTimesUnusedScore)")
                                    .font(
                                        .subheadline.monospacedDigit().weight(
                                            row.costTimesUnusedScore > 0 ? .bold : .regular)
                                    )
                                    .foregroundStyle(row.costTimesUnusedScore > 0 ? .orange : .secondary)
                                    .frame(width: 105, alignment: .trailing)

                                HStack(spacing: 4) {
                                    if let artifact = model.artifact(for: row.artifactID),
                                        let disableKind = disableKind(for: artifact)
                                    {
                                        Button("Disable…") {
                                            do {
                                                try model.openFixPreview(
                                                    for: FixRequest(kind: disableKind, artifact: artifact)
                                                )
                                            } catch {
                                                model.lastErrorMessage = error.localizedDescription
                                            }
                                        }
                                        .controlSize(.mini)
                                    }
                                }
                                .frame(width: 75, alignment: .trailing)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)

                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func formatLastUsed(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: model.environment.now())
    }

    private func disableKind(for artifact: Artifact) -> FixKind? {
        guard artifact.enabled, artifact.scope != .managed, artifact.scope != .builtIn else {
            return nil
        }
        let support = model.workspace.fixSupport(for: artifact.agent)
        switch artifact.kind {
        case .mcpServer where support.supportedKinds.contains(.disableMCPServer):
            return .disableMCPServer
        case .skill where support.supportedKinds.contains(.disableSkill):
            return .disableSkill
        default:
            return nil
        }
    }
}
