import BentoCore
import SwiftUI

/// Repository detail workspace featuring a segmented agent picker and four tabs:
/// `Budget`, `Resolution`, `Usage`, and `Hygiene` (`PLAN.md` §6.7).
struct RepoDetailView: View {
    let model: BentoAppModel

    var body: some View {
        @Bindable var bindableModel = model
        if let repo = model.selectedRepository {
            VStack(alignment: .leading, spacing: 0) {
                // Header: repo title, path, pin/reveal actions, segmented agent picker, and tab bar
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: repo.isPinned ? "pin.circle.fill" : "folder.fill")
                            .font(.title2)
                            .foregroundStyle(repo.isPinned ? .orange : .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(repo.displayName)
                                .font(.title3.weight(.bold))
                            Text(model.abbreviateHomePath(repo.path))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()

                        Button {
                            Task {
                                try? await model.togglePinRepository(path: repo.path)
                            }
                        } label: {
                            Label(repo.isPinned ? "Pinned" : "Pin", systemImage: repo.isPinned ? "pin.slash" : "pin")
                        }
                        .controlSize(.small)

                        Button {
                            model.revealPathInFinder(repo.path)
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                        }
                        .controlSize(.small)
                    }

                    HStack(spacing: 16) {
                        Picker("Agent", selection: $bindableModel.selectedRepoAgent) {
                            ForEach(AgentID.allCases, id: \.self) { agent in
                                Text(agent.shortDisplayName).tag(agent)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityLabel("Selected coding agent")
                        .accessibilityIdentifier("repo-agent-picker")

                        Picker("Tab", selection: $bindableModel.selectedRepoTab) {
                            ForEach(RepoDetailTab.allCases) { tab in
                                Text(tab.title).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 360)
                        .accessibilityLabel("Repository detail tab")
                        .accessibilityIdentifier("repo-tab-picker")
                    }
                }
                .padding(16)
                .background(Color.primary.opacity(0.02))

                Divider()

                Group {
                    switch model.selectedRepoTab {
                    case .budget:
                        BudgetTabView(model: model, repo: repo)
                    case .resolution:
                        ResolutionTabView(model: model, repo: repo)
                    case .usage:
                        UsageTabView(model: model, repo: repo)
                    case .hygiene:
                        HygieneTabView(model: model, repo: repo)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView {
                Label("No Repository Selected", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Select a discovered repository from the sidebar or add a workspace folder in Settings.")
            } actions: {
                Button("Open Settings") {
                    model.selectedSection = .settings
                }
            }
        }
    }
}
