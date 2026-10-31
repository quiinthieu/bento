import BentoCore
import SwiftUI

/// Overview dashboard displaying detected agents, total artifacts, top findings, and biggest budget consumers (`PLAN.md` §6.7).
struct OverviewView: View {
    let model: BentoAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Workspace Overview")
                            .font(.title2.weight(.bold))
                            .accessibilityIdentifier("overview-heading")
                        Text("Home: \(model.abbreviateHomePath(model.environment.home.path))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                // Summary Metric Cards
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    spacing: 12
                ) {
                    OverviewStatCard(
                        title: "Detected Agents",
                        value: "\(model.detectedAgentCount) / \(AgentID.allCases.count)",
                        subtitle: "Configured on this Mac",
                        symbolName: "cpu",
                        tint: .blue
                    ) {
                        model.selectedSection = .agents
                    }

                    OverviewStatCard(
                        title: "Total Artifacts",
                        value: "\(model.totalArtifactCount)",
                        subtitle: "Rules, skills, MCP, settings",
                        symbolName: "doc.on.doc",
                        tint: .teal
                    ) {
                        model.selectedSection = .agents
                    }

                    OverviewStatCard(
                        title: "Repositories",
                        value: "\(model.repositories.count)",
                        subtitle: "\(model.repositories.filter(\.isPinned).count) pinned",
                        symbolName: "folder",
                        tint: .indigo
                    ) {
                        model.selectedSection = .repos
                    }

                    OverviewStatCard(
                        title: "Hygiene Findings",
                        value: "\(model.allFindings.count)",
                        subtitle: "\(model.errorFindingCount) errors, \(model.warningFindingCount) warnings",
                        symbolName: "checkmark.shield",
                        tint: model.allFindings.isEmpty ? .green : .orange
                    ) {
                        model.selectedSection = .findings
                    }
                }

                // Detected Agents Strip
                GroupBox("Detected Coding Agents") {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10)
                        ],
                        spacing: 10
                    ) {
                        ForEach(AgentID.allCases, id: \.self) { agent in
                            let detection = model.snapshot?.detections[agent]
                            let isDetected = detection?.isDetected ?? false
                            HStack(spacing: 10) {
                                Image(systemName: agent.symbolName)
                                    .font(.title3)
                                    .foregroundStyle(isDetected ? .blue : .secondary)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(agent.displayName)
                                            .font(.subheadline.weight(.semibold))
                                        Circle()
                                            .fill(isDetected ? Color.green : Color.secondary.opacity(0.35))
                                            .frame(width: 7, height: 7)
                                    }
                                    Text(
                                        agent.supportsFullBudgetAndUsage
                                            ? "Full audit & budget"
                                            : "Inventory + rules hygiene"
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.primary.opacity(0.03))
                            )
                        }
                    }
                    .padding(.top, 4)
                }

                HStack(alignment: .top, spacing: 16) {
                    // Top Hygiene Findings
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            if model.allFindings.isEmpty {
                                Text("No hygiene or unused-artifact findings detected.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 8)
                            } else {
                                ForEach(Array(model.allFindings.prefix(6))) { finding in
                                    Button {
                                        model.inspectorSelection = .finding(finding.id)
                                        model.selectedSection = .findings
                                    } label: {
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: finding.severity.symbolName)
                                                .foregroundStyle(finding.severity.tintColor)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(finding.kind.displayName)
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(finding.severity.tintColor)
                                                Text(finding.message)
                                                    .font(.subheadline)
                                                    .lineLimit(2)
                                                    .multilineTextAlignment(.leading)
                                            }
                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    Divider()
                                }
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        HStack {
                            Label("Top Findings", systemImage: "exclamationmark.shield")
                            Spacer()
                            Button("View All") {
                                model.selectedSection = .findings
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // Biggest Budget Consumers
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            if model.biggestBudgetConsumers.isEmpty {
                                Text("Select or add a repository to inspect pre-prompt token consumers.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 8)
                            } else {
                                ForEach(Array(model.biggestBudgetConsumers.prefix(8))) { consumer in
                                    Button {
                                        model.selectedRepoPath = consumer.repoPath
                                        model.selectedRepoAgent = consumer.agent
                                        model.selectedRepoTab = .budget
                                        model.selectedSection = .repos
                                        model.inspectorSelection = .budgetItem(consumer.item, consumer.agent)
                                    } label: {
                                        HStack(spacing: 8) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(consumer.item.label)
                                                    .font(.subheadline.weight(.medium))
                                                    .lineLimit(1)
                                                Text(
                                                    "\(consumer.agent.shortDisplayName) • \(consumer.repoName) • \(consumer.item.category.displayName)"
                                                )
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                            }
                                            Spacer()
                                            ConfidenceBadgeView(confidence: consumer.item.confidence)
                                            Text("\(consumer.item.tokens) tok")
                                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help(consumer.item.method)
                                    Divider()
                                }
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        HStack {
                            Label("Biggest Pre-Prompt Consumers", systemImage: "flame")
                            Spacer()
                            if model.selectedRepoPath != nil {
                                Button("Open Repo Budget") {
                                    model.selectedRepoTab = .budget
                                    model.selectedSection = .repos
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
    }
}

private struct OverviewStatCard: View {
    let title: String
    let value: String
    let subtitle: String
    let symbolName: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbolName)
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Text(value)
                    .font(.title2.monospacedDigit().weight(.bold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(tint.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Reusable pill badge for `Confidence` (`Exact` / `Est.` / `Measured`).
public struct ConfidenceBadgeView: View {
    public let confidence: Confidence

    public init(confidence: Confidence) {
        self.confidence = confidence
    }

    public var body: some View {
        Text(confidence.badgeTitle)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(confidence.badgeColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(confidence.badgeColor.opacity(0.14))
            )
            .accessibilityLabel("Confidence: \(confidence.rawValue)")
    }
}

/// Reusable pill badge for `Scope` (`Managed` / `Local` / `Project` / `Directory` / `User` / `Built-in`).
public struct ScopeBadgeView: View {
    public let scope: Scope

    public init(scope: Scope) {
        self.scope = scope
    }

    public var body: some View {
        Text(scope.badgeTitle)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(scope.badgeColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(scope.badgeColor.opacity(0.15))
            )
            .accessibilityLabel("Scope: \(scope.badgeTitle)")
    }
}
