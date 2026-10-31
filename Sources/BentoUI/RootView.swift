import BentoCore
import SwiftUI

/// Top-level `NavigationSplitView` (Sidebar → Content → Inspector) rendered inside the main application window (`PLAN.md` §6.7).
public struct RootView: View {
    /// Configuration providing the window title and display metadata.
    public let configuration: RootWindowConfiguration

    private let injectedModel: BentoAppModel?
    private let bootstrap = AppSceneBootstrap.shared

    /// Creates the root view with the provided window configuration and optional pre-constructed `BentoAppModel`.
    public init(
        configuration: RootWindowConfiguration = RootWindowConfiguration(),
        model: BentoAppModel? = nil
    ) {
        self.configuration = configuration
        self.injectedModel = model
    }

    private var activeModel: BentoAppModel? {
        injectedModel ?? bootstrap.appModel
    }

    public var body: some View {
        Group {
            if let model = activeModel {
                @Bindable var bindableModel = model
                NavigationSplitView {
                    SidebarView(model: model)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
                } detail: {
                    VStack(spacing: 0) {
                        BannersHeaderView(model: model)
                        MainContentView(model: model)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .inspector(isPresented: $bindableModel.isInspectorPresented) {
                        InspectorView(model: model)
                            .inspectorColumnWidth(min: 260, ideal: 310, max: 420)
                    }
                }
                .navigationTitle(resolvedTitle(for: model))
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        HStack(spacing: 6) {
                            Image(systemName: model.allowChanges ? "lock.open.fill" : "lock.fill")
                                .foregroundStyle(model.allowChanges ? .orange : .secondary)
                            Text(model.allowChanges ? "Changes Allowed" : "Read-Only")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(model.allowChanges ? .orange : .secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(model.allowChanges ? Color.orange.opacity(0.14) : Color.secondary.opacity(0.12))
                        )
                        .help(
                            model.allowChanges
                                ? "Allow changes is enabled in Settings."
                                : "Read-only mode: enable 'Allow changes' in Settings to apply or undo fixes."
                        )

                        Button {
                            Task {
                                await model.refreshAll()
                            }
                        } label: {
                            Label("Rescan", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isRefreshing)
                        .help("Rescan agent configs, logs, budgets, and hygiene (⌘R)")

                        Button {
                            model.isInspectorPresented.toggle()
                        } label: {
                            Label("Inspector", systemImage: "sidebar.trailing")
                        }
                        .help("Toggle Inspector (⌥⌘I)")
                    }
                }
                .sheet(isPresented: $bindableModel.isShowingOnboarding) {
                    OnboardingSheet(model: model)
                }
                .sheet(
                    item: Binding(
                        get: { model.activeFixSheet },
                        set: { newValue in
                            if newValue == nil {
                                model.dismissFixSheet()
                            }
                        }
                    )
                ) { sheetState in
                    FixPreviewSheet(model: model, state: sheetState)
                }
                .sheet(
                    item: Binding(
                        get: { model.activeTokenCountPreview },
                        set: { newValue in
                            model.activeTokenCountPreview = newValue
                        }
                    )
                ) { preview in
                    TokenCountPreviewSheet(model: model, preview: preview)
                }
            } else {
                ProgressView("Initializing \(configuration.windowTitle)…")
                    .frame(minWidth: 960, minHeight: 640)
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(configuration.windowTitle)
        .task {
            guard injectedModel == nil else { return }
            await bootstrap.startIfNeeded()
        }
    }

    private func resolvedTitle(for model: BentoAppModel) -> String {
        if configuration.windowTitle == Product.name {
            return model.effectiveProductName
        }
        return configuration.windowTitle
    }
}

private struct BannersHeaderView: View {
    let model: BentoAppModel

    var body: some View {
        VStack(spacing: 6) {
            ForEach(model.tccNotices) { notice in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("macOS Folder Protection (\(notice.protectedFolderName))")
                            .font(.subheadline.weight(.semibold))
                        Text(notice.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
            }

            if let error = model.lastErrorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") {
                        model.lastErrorMessage = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.12))
            }

            if let status = model.statusBannerMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(status)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") {
                        model.statusBannerMessage = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.12))
            }
        }
    }
}

private struct MainContentView: View {
    let model: BentoAppModel

    var body: some View {
        switch model.selectedSection {
        case .overview:
            OverviewView(model: model)
        case .repos:
            RepoDetailView(model: model)
        case .agents:
            AgentsView(model: model)
        case .findings:
            FindingsView(model: model)
        case .usage:
            GlobalUsageView(model: model)
        case .fixHistory:
            FixHistoryView(model: model)
        case .settings:
            SettingsView(model: model)
        }
    }
}
