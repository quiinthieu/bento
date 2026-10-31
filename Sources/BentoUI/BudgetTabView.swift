import AppKit
import BentoCore
import BentoFixes
import Charts
import SwiftUI

/// Swift Charts horizontal stacked context budget card with coloured categories, diagonal hatching for
/// deferred/on-invoke items, measured first-turn median marker line, and full VoiceOver segment labels (`PLAN.md` §6.7).
public struct BudgetChartCardView: View {
    public let summaries: [BudgetChartSummary]
    public let selectedAgent: AgentID

    public init(summaries: [BudgetChartSummary], selectedAgent: AgentID) {
        self.summaries = summaries
        self.selectedAgent = selectedAgent
    }

    public var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if summaries.isEmpty {
                    Text("No token budget data available for this repository.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    Chart {
                        ForEach(summaries) { summary in
                            ForEach(summary.segments) { segment in
                                BarMark(
                                    x: .value("Tokens", segment.tokens),
                                    y: .value("Agent", summary.agentDisplayName)
                                )
                                .foregroundStyle(Self.fillStyle(for: segment))
                                .opacity(summary.agent == selectedAgent ? 1.0 : 0.72)
                                .accessibilityLabel(segment.accessibilityLabel)
                                .accessibilityValue(segment.accessibilityValue)
                            }

                            if let measured = summary.measuredFirstTurnInput {
                                RuleMark(x: .value("Measured 1st-Turn Median", measured))
                                    .foregroundStyle(Color.red)
                                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                                    .annotation(position: .top, alignment: .leading) {
                                        if summary.agent == selectedAgent {
                                            Text("Measured: \(measured) tok")
                                                .font(.caption2.monospacedDigit().weight(.semibold))
                                                .foregroundStyle(.red)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(
                                                    Capsule().fill(Color.red.opacity(0.12))
                                                )
                                        }
                                    }
                                    .accessibilityLabel(
                                        summary.measuredMarkerAccessibilityLabel
                                            ?? "Measured first-turn median: \(measured) tokens"
                                    )
                            }
                        }
                    }
                    .chartXAxisLabel("Context Tokens (solid = pre-prompt, hatched = deferred / on-invoke)")
                    .frame(minHeight: CGFloat(max(130, summaries.count * 46)))
                    .accessibilityIdentifier("budget-stacked-chart")
                    .accessibilityLabel(combinedChartAccessibilitySummary)

                    // Category Legend + Explicit VoiceOver Segment Rotor Children
                    FlowLegendAndAccessibilitySegmentsView(summaries: summaries, selectedAgent: selectedAgent)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Label("Context Budget Comparison Across Agents", systemImage: "chart.bar.xaxis")
                Spacer()
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.blue)
                            .frame(width: 12, height: 8)
                        Text("Pre-prompt")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Self.hatchedImagePaint(for: .purple))
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .strokeBorder(Color.purple.opacity(0.7), lineWidth: 1)
                            )
                            .frame(width: 12, height: 8)
                        Text("Deferred / On-invoke")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Rectangle()
                            .fill(Color.red)
                            .frame(width: 12, height: 2)
                        Text("Measured 1st-Turn")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var combinedChartAccessibilitySummary: String {
        summaries.map(\.chartSummaryAccessibilityLabel).joined(separator: "; ")
    }

    private static func fillStyle(for segment: BudgetChartSegment) -> AnyShapeStyle {
        if segment.isPrePrompt {
            return AnyShapeStyle(segment.category.chartColor)
        }
        return AnyShapeStyle(hatchedImagePaint(for: segment.category.chartColor))
    }

    static func hatchedImagePaint(for color: Color) -> ImagePaint {
        let nsColor = NSColor(color)
        let tileSize = NSSize(width: 10, height: 10)
        let tile = NSImage(size: tileSize, flipped: false) { rect in
            nsColor.withAlphaComponent(0.18).setFill()
            rect.fill()

            nsColor.withAlphaComponent(0.85).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.6
            path.move(to: NSPoint(x: -2, y: 2))
            path.line(to: NSPoint(x: 2, y: -2))
            path.move(to: NSPoint(x: 0, y: 10))
            path.line(to: NSPoint(x: 10, y: 0))
            path.move(to: NSPoint(x: 8, y: 12))
            path.line(to: NSPoint(x: 12, y: 8))
            path.stroke()
            return true
        }
        return ImagePaint(image: Image(nsImage: tile), scale: 1.0)
    }
}

private struct FlowLegendAndAccessibilitySegmentsView: View {
    let summaries: [BudgetChartSummary]
    let selectedAgent: AgentID

    var body: some View {
        let activeSummary = summaries.first(where: { $0.agent == selectedAgent }) ?? summaries.first
        if let summary = activeSummary {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(summary.segments) { segment in
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(
                                        segment.isPrePrompt
                                            ? AnyShapeStyle(segment.category.chartColor)
                                            : AnyShapeStyle(
                                                BudgetChartCardView.hatchedImagePaint(for: segment.category.chartColor)
                                            )
                                    )
                                    .frame(width: 10, height: 10)
                                Text(segment.categoryDisplayName)
                                    .font(.caption2.weight(.medium))
                                Text("\(segment.tokens)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(Color.primary.opacity(0.05))
                            )
                            .accessibilityHidden(true)
                        }

                        if let markerLabel = summary.measuredMarkerAccessibilityLabel {
                            HStack(spacing: 4) {
                                Image(systemName: "line.diagonal")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                Text(markerLabel)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.red)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.red.opacity(0.10)))
                            .accessibilityHidden(true)
                        }
                    }
                }
            }
            .background(
                BudgetChartAccessibilityRotorRepresentable(summary: summary)
            )
        }
    }
}

/// AppKit accessibility bridge exposing deterministic `NSAccessibilityElement` children for every
/// chart segment and measured marker to VoiceOver, XCUITest, and headless `NSHostingView` tests.
private struct BudgetChartAccessibilityRotorRepresentable: NSViewRepresentable {
    let summary: BudgetChartSummary

    func makeNSView(context: Context) -> BudgetChartAccessibilityRotorNSView {
        let view = BudgetChartAccessibilityRotorNSView()
        view.update(summary: summary)
        return view
    }

    func updateNSView(_ nsView: BudgetChartAccessibilityRotorNSView, context: Context) {
        nsView.update(summary: summary)
    }
}

private final class BudgetChartAccessibilityRotorNSView: NSView {
    private var segmentElements: [NSAccessibilityElement] = []

    func update(summary: BudgetChartSummary) {
        var elements: [NSAccessibilityElement] = []
        for (idx, segment) in summary.segments.enumerated() {
            let elem = NSAccessibilityElement()
            elem.setAccessibilityParent(self)
            elem.setAccessibilityRole(.staticText)
            elem.setAccessibilityLabel(segment.accessibilityLabel)
            elem.setAccessibilityValue(segment.accessibilityValue)
            elem.setAccessibilityIdentifier("chart-segment-\(segment.id)")
            elem.setAccessibilityFrameInParentSpace(
                NSRect(x: CGFloat(idx * 80), y: 0, width: 76, height: 22)
            )
            elements.append(elem)
        }

        if let markerLabel = summary.measuredMarkerAccessibilityLabel {
            let marker = NSAccessibilityElement()
            marker.setAccessibilityParent(self)
            marker.setAccessibilityRole(.staticText)
            marker.setAccessibilityLabel(markerLabel)
            marker.setAccessibilityValue(
                summary.measuredFirstTurnInput.map { "\($0) tokens" } ?? ""
            )
            marker.setAccessibilityIdentifier("chart-measured-marker-\(summary.agent.rawValue)")
            marker.setAccessibilityFrameInParentSpace(
                NSRect(x: CGFloat(elements.count * 80), y: 0, width: 120, height: 22)
            )
            elements.append(marker)
        }

        self.segmentElements = elements
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .group
    }

    override func accessibilityLabel() -> String? {
        "Context budget chart segments"
    }

    override func accessibilityIdentifier() -> String {
        "budget-chart-segments-rotor"
    }

    override func accessibilityChildren() -> [Any]? {
        segmentElements
    }
}

/// Repository Detail → `Budget` tab (`PLAN.md` §6.7).
struct BudgetTabView: View {
    let model: BentoAppModel
    let repo: DiscoveredRepo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BudgetChartCardView(
                    summaries: model.currentRepoChartSummaries,
                    selectedAgent: model.selectedRepoAgent
                )

                if !model.selectedRepoAgent.supportsFullBudgetAndUsage {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(
                                "\(model.selectedRepoAgent.displayName) supports Inventory & Rules Hygiene in v1",
                                systemImage: "info.circle.fill"
                            )
                            .font(.headline)
                            .foregroundStyle(.blue)
                            Text(
                                "Per-session pre-prompt token budgets and log usage are modeled for Claude Code, Codex CLI, Gemini CLI, and Copilot CLI. Switch to the Hygiene tab or Agents section to inspect \(model.selectedRepoAgent.displayName) rules, limits, and MCP servers."
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                        .padding(6)
                    }
                } else if let budget = model.currentRepoBudget {
                    BudgetSelectedAgentSummaryBar(model: model, repo: repo, budget: budget)
                    BudgetItemsTableCard(model: model, budget: budget)
                } else {
                    ContentUnavailableView(
                        "No Budget Computed",
                        systemImage: "chart.bar.doc.horizontal",
                        description: Text("Click Rescan (⌘R) to compute context budgets for \(repo.displayName).")
                    )
                }
            }
            .padding(16)
        }
    }
}

private struct BudgetSelectedAgentSummaryBar: View {
    let model: BentoAppModel
    let repo: DiscoveredRepo
    let budget: Budget

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(budget.agent.displayName) Pre-Prompt Load")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(budget.prePromptTokens) tokens")
                        .font(.title3.monospacedDigit().weight(.bold))
                    if let window = budget.contextWindow, window > 0 {
                        let pct = (Double(budget.prePromptTokens) / Double(window)) * 100.0
                        Text(String(format: "(%.1f%% of %d)", pct, window))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let measured = budget.measuredFirstTurnInput {
                Divider().frame(height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Measured 1st-Turn Median")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text("\(measured) tokens")
                            .font(.headline.monospacedDigit())
                        ConfidenceBadgeView(confidence: .measured)
                    }
                }
            }

            Spacer()

            if let provider = exactAPIProvider(for: budget.agent) {
                if model.isTokenCountAPIEnabled(for: provider) && model.hasStoredAPIKey(for: provider) {
                    Button {
                        Task {
                            do {
                                _ = try await model.prepareExactTokenCountPreview(
                                    for: provider,
                                    repoPath: repo.path
                                )
                            } catch {
                                model.lastErrorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        Label("Preview Exact API Count…", systemImage: "checkmark.seal")
                    }
                    .controlSize(.small)
                } else {
                    Button("Configure Exact API Count…") {
                        model.selectedSection = .settings
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private func exactAPIProvider(for agent: AgentID) -> TokenCountAPIProviderID? {
        switch agent {
        case .claudeCode:
            return .anthropic
        case .gemini:
            return .gemini
        default:
            return nil
        }
    }
}

private struct BudgetItemsTableCard: View {
    let model: BentoAppModel
    let budget: Budget

    var body: some View {
        GroupBox("Budget Items (\(budget.items.count)) — hover any row to inspect counting method") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("Item")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Category")
                        .frame(width: 145, alignment: .leading)
                    Text("Mode")
                        .frame(width: 105, alignment: .leading)
                    Text("Tokens")
                        .frame(width: 85, alignment: .trailing)
                    Text("Confidence")
                        .frame(width: 85, alignment: .center)
                    Text("Actions")
                        .frame(width: 90, alignment: .trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)

                Divider()

                ForEach(Array(budget.items.enumerated()), id: \.offset) { _, item in
                    let linkedArtifact = item.artifactID.flatMap { model.artifact(for: $0) }
                    HStack(spacing: 10) {
                        Button {
                            model.inspectorSelection = .budgetItem(item, budget.agent)
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(item.category.chartColor)
                                    .frame(width: 8, height: 8)
                                Text(item.label)
                                    .font(.subheadline)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Text(item.category.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 145, alignment: .leading)

                        Text(item.countsTowardPrePrompt ? "Pre-prompt" : "Deferred")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(item.countsTowardPrePrompt ? .primary : .secondary)
                            .frame(width: 105, alignment: .leading)

                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(item.tokens)")
                                .font(.subheadline.monospacedDigit().weight(.medium))
                            if let range = item.range {
                                Text("\(range.lowerBound)–\(range.upperBound)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 85, alignment: .trailing)

                        ConfidenceBadgeView(confidence: item.confidence)
                            .frame(width: 85, alignment: .center)

                        HStack(spacing: 4) {
                            if let artifact = linkedArtifact {
                                Button {
                                    model.revealArtifactInFinder(artifact)
                                } label: {
                                    Image(systemName: "folder")
                                }
                                .buttonStyle(.borderless)
                                .help("Reveal in Finder")

                                if let fixKind = quickDisableFixKind(for: artifact) {
                                    Button {
                                        do {
                                            try model.openFixPreview(for: FixRequest(kind: fixKind, artifact: artifact))
                                        } catch {
                                            model.lastErrorMessage = error.localizedDescription
                                        }
                                    } label: {
                                        Image(systemName: "wand.and.stars")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Preview \(fixKind.displayName)")
                                }
                            }
                        }
                        .frame(width: 90, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .help(item.method)

                    Divider()
                }
            }
        }
    }

    private func quickDisableFixKind(for artifact: Artifact) -> FixKind? {
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
