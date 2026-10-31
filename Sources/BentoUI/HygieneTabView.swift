import BentoCore
import SwiftUI

/// Repository Detail → `Hygiene` tab rendering findings with side-by-side 1-based line spans (`PLAN.md` §6.7).
struct HygieneTabView: View {
    let model: BentoAppModel
    let repo: DiscoveredRepo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let findings = model.currentRepoFindings
                if findings.isEmpty {
                    ContentUnavailableView(
                        "No Hygiene Findings",
                        systemImage: "checkmark.seal",
                        description: Text(
                            "No duplicate rules, opposing directives, size limits, broken imports, or unused artifacts detected for \(model.selectedRepoAgent.displayName) in \(repo.displayName)."
                        )
                    )
                } else {
                    ForEach(findings) { finding in
                        FindingCardView(finding: finding, model: model)
                    }
                }
            }
            .padding(16)
        }
    }
}

/// Top-level Sidebar → `Findings` view across all repositories and agents.
struct FindingsView: View {
    let model: BentoAppModel

    private var filteredFindings: [Finding] {
        model.allFindings.filter { finding in
            if let selectedKindFilter = model.findingsKindFilter, finding.kind != selectedKindFilter {
                return false
            }
            if let selectedSeverityFilter = model.findingsSeverityFilter, finding.severity != selectedSeverityFilter {
                return false
            }
            return true
        }
    }

    var body: some View {
        @Bindable var bindableModel = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rules & Configuration Hygiene")
                            .font(.title2.weight(.bold))
                        Text("\(filteredFindings.count) active finding(s) across discovered agents and repositories")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    Picker("Kind", selection: $bindableModel.findingsKindFilter) {
                        Text("All Kinds").tag(Finding.Kind?.none)
                        ForEach(Finding.Kind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(Finding.Kind?.some(kind))
                        }
                    }
                    .frame(width: 185)

                    Picker("Severity", selection: $bindableModel.findingsSeverityFilter) {
                        Text("All Severities").tag(Severity?.none)
                        Text("Errors").tag(Severity?.some(.error))
                        Text("Warnings").tag(Severity?.some(.warning))
                        Text("Info").tag(Severity?.some(.info))
                    }
                    .frame(width: 150)
                }

                if filteredFindings.isEmpty {
                    ContentUnavailableView(
                        "No Matching Findings",
                        systemImage: "checkmark.shield",
                        description: Text("Your agent rules and configurations look clean for the active filter.")
                    )
                } else {
                    ForEach(filteredFindings) { finding in
                        FindingCardView(finding: finding, model: model)
                    }
                }
            }
            .padding(20)
        }
    }
}

/// Renders a single `Finding` with severity badge, suggested Fix Preview triggers, and side-by-side span columns.
struct FindingCardView: View {
    let finding: Finding
    let model: BentoAppModel

    var body: some View {
        let excerpts = model.spanExcerpts(for: finding)

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(finding.message)
                    .font(.subheadline)
                    .textSelection(.enabled)

                if !excerpts.isEmpty {
                    SideBySideSpansView(excerpts: excerpts, model: model)
                }

                if !finding.suggestedFixes.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(finding.suggestedFixes, id: \.self) { fixKind in
                            Button {
                                do {
                                    try model.openSuggestedFix(fixKind, for: finding)
                                } catch {
                                    model.lastErrorMessage = error.localizedDescription
                                }
                            } label: {
                                Label("Preview: \(fixKind.displayName)…", systemImage: "wand.and.stars")
                            }
                            .controlSize(.small)
                        }
                        Spacer()
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: finding.severity.symbolName)
                    .foregroundStyle(finding.severity.tintColor)
                Text(finding.kind.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(finding.severity.tintColor)

                let agents = involvedAgents(for: finding)
                ForEach(agents, id: \.self) { agent in
                    Text(agent.shortDisplayName)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }

                Spacer()

                Button("Inspect") {
                    model.inspectorSelection = .finding(finding.id)
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Button("Dismiss") {
                    model.toggleDismissFinding(finding, dismissed: true)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func involvedAgents(for finding: Finding) -> [AgentID] {
        var seen: Set<AgentID> = []
        var list: [AgentID] = []
        for id in finding.artifacts {
            if let agent = model.artifact(for: id)?.agent, seen.insert(agent).inserted {
                list.append(agent)
            }
        }
        return list.sorted()
    }
}

/// Side-by-side monospaced 1-based line viewer for duplicate and conflicting rule spans (`PLAN.md` §6.7).
struct SideBySideSpansView: View {
    let excerpts: [SpanExcerpt]
    let model: BentoAppModel

    var body: some View {
        let columns: [GridItem] =
            excerpts.count >= 2
            ? [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
            : [GridItem(.flexible())]

        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(excerpts) { excerpt in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("\(excerpt.displayPath) (\(excerpt.lineRangeLabel))")
                            .font(.caption.monospaced().weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        Button {
                            model.revealPathInFinder(excerpt.location.path)
                        } label: {
                            Image(systemName: "folder")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")

                        Button {
                            model.openPathInEditor(excerpt.location.path)
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help("Open in editor")
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(excerpt.lines) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(line.lineNumber)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, alignment: .trailing)
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.caption.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 1)
                            .padding(.horizontal, 4)
                            .background(
                                line.isHighlighted ? Color.yellow.opacity(0.16) : Color.clear
                            )
                        }
                    }
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.04))
                    )
                }
            }
        }
    }
}
