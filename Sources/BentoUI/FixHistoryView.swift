import BentoCore
import BentoFixes
import SwiftUI

/// Sidebar → `Fix History` view listing applied, undone, rolled-back, and failed fixes with one-click Undo (`PLAN.md` §6.6, §6.7).
struct FixHistoryView: View {
    let model: BentoAppModel

    var body: some View {
        @Bindable var bindableModel = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fix History & Backups")
                            .font(.title2.weight(.bold))
                        Text(
                            "Every configuration edit is backed up under \(model.abbreviateHomePath(model.supportDirectory.appendingPathComponent("Backups").path)) before applying"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if !model.allowChanges {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.orange)
                        Text("Read-only mode: enable \"Allow changes\" in Settings to undo applied fixes.")
                            .font(.caption)
                        Spacer()
                        Button("Open Settings") {
                            model.selectedSection = .settings
                        }
                        .controlSize(.mini)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                }

                if model.fixHistory.isEmpty {
                    ContentUnavailableView(
                        "No Fixes Applied Yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text(
                            "Previewed and applied fixes will appear here with backup paths and Undo controls.")
                    )
                } else {
                    ForEach(model.fixHistory) { entry in
                        FixJournalRowCard(entry: entry, model: model)
                    }
                }
            }
            .padding(20)
        }
        .confirmationDialog(
            "Overwrite Post-Apply Edits from Backup?",
            isPresented: Binding(
                get: { model.pendingForceUndoEntry != nil },
                set: { presented in
                    if !presented {
                        bindableModel.pendingForceUndoEntry = nil
                    }
                }
            ),
            presenting: model.pendingForceUndoEntry
        ) { entry in
            Button("Force Undo & Restore Backup", role: .destructive) {
                Task {
                    await model.undoFix(id: entry.id, force: true)
                }
            }
            Button("Cancel", role: .cancel) {
                bindableModel.pendingForceUndoEntry = nil
            }
        } message: { entry in
            Text(
                "One or more files touched by \(entry.kind.displayName) (\(entry.id)) were edited after the fix was applied. Force Undo restores the exact pre-apply backup."
            )
        }
    }
}

private struct FixJournalRowCard: View {
    let entry: FixJournalEntry
    let model: BentoAppModel

    var body: some View {
        let decodedSummary = decodePlanSummary(entry.planJSON)

        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let summary = decodedSummary {
                    Text(summary.summary)
                        .font(.subheadline)
                    if !summary.affectedPaths.isEmpty {
                        Text(
                            "Paths: "
                                + summary.affectedPaths.map { model.abbreviateHomePath($0) }.joined(separator: ", ")
                        )
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    Text("Backup:")
                        .font(.caption2.weight(.semibold))
                    Text(model.abbreviateHomePath(entry.backupDir))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !entry.backupDir.isEmpty {
                        Button("Reveal Backup") {
                            model.revealPathInFinder(entry.backupDir)
                        }
                        .buttonStyle(.link)
                        .font(.caption2)
                    }
                }

                if let error = entry.error, !error.isEmpty {
                    Text("Error: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Text(entry.kind.displayName)
                    .font(.subheadline.weight(.semibold))
                StatusPill(status: entry.status)
                Text(entry.createdAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()

                Button("Inspect") {
                    model.inspectorSelection = .fixJournal(entry.id)
                }
                .buttonStyle(.borderless)
                .font(.caption)

                if entry.status == .applied {
                    Button("Undo") {
                        Task {
                            await model.undoFix(id: entry.id)
                        }
                    }
                    .controlSize(.small)
                    .disabled(!model.allowChanges)
                    .accessibilityIdentifier("undo-fix-\(entry.id)")
                }
            }
        }
    }

    private func decodePlanSummary(_ rawJSON: String) -> PersistedFixPlanSummary? {
        guard let data = rawJSON.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PersistedFixPlanSummary.self, from: data)
    }
}

private struct StatusPill: View {
    let status: FixJournalStatus

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }

    private var label: String {
        switch status {
        case .pending:
            return "Pending"
        case .applied:
            return "Applied"
        case .undone:
            return "Undone"
        case .rolledBack:
            return "Rolled Back"
        case .failed:
            return "Failed"
        }
    }

    private var tint: Color {
        switch status {
        case .pending:
            return .secondary
        case .applied:
            return .green
        case .undone:
            return .blue
        case .rolledBack:
            return .orange
        case .failed:
            return .red
        }
    }
}
