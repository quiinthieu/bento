import BentoCore
import SwiftUI

/// Left column of `NavigationSplitView` listing primary sections and searchable, pinnable repositories (`PLAN.md` §6.7).
struct SidebarView: View {
    let model: BentoAppModel

    var body: some View {
        @Bindable var bindableModel = model
        List(selection: $bindableModel.selectedSection) {
            Section("Workspace") {
                ForEach(SidebarSection.allCases) { section in
                    Label {
                        HStack {
                            Text(section.title)
                            Spacer()
                            if let count = badgeCount(for: section), count > 0 {
                                Text("\(count)")
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                            }
                        }
                    } icon: {
                        Image(systemName: section.symbolName)
                    }
                    .tag(section)
                    .accessibilityIdentifier("sidebar-\(section.rawValue)")
                }
            }

            Section {
                TextField("Filter repos…", text: $bindableModel.repoSearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("sidebar-repo-search")

                if model.filteredRepositories.isEmpty {
                    Text(model.repositories.isEmpty ? "No repositories discovered" : "No matching repositories")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.filteredRepositories, id: \.path) { repo in
                        HStack(spacing: 6) {
                            Button {
                                Task {
                                    await model.selectRepository(repo.path)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: repo.isPinned ? "pin.fill" : "folder")
                                        .foregroundStyle(repo.isPinned ? .orange : .secondary)
                                        .font(.caption)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(repo.displayName)
                                            .font(
                                                .subheadline.weight(
                                                    model.selectedRepoPath == repo.path ? .semibold : .regular)
                                            )
                                            .lineLimit(1)
                                        Text(model.abbreviateHomePath(repo.path))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("repo-row-\(repo.displayName)")

                            Button {
                                Task {
                                    try? await model.togglePinRepository(path: repo.path)
                                }
                            } label: {
                                Image(systemName: repo.isPinned ? "pin.slash" : "pin")
                                    .font(.caption2)
                            }
                            .buttonStyle(.borderless)
                            .help(repo.isPinned ? "Unpin repository" : "Pin repository")
                            .accessibilityLabel(repo.isPinned ? "Unpin \(repo.displayName)" : "Pin \(repo.displayName)")
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                HStack {
                    Text("Repositories")
                    Spacer()
                    Text("\(model.filteredRepositories.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func badgeCount(for section: SidebarSection) -> Int? {
        switch section {
        case .overview:
            return nil
        case .repos:
            return model.repositories.count
        case .agents:
            return model.detectedAgentCount
        case .findings:
            return model.allFindings.count
        case .usage:
            return model.unusedGlobalUsageCount
        case .fixHistory:
            return model.fixHistory.count
        case .settings:
            return nil
        }
    }
}
