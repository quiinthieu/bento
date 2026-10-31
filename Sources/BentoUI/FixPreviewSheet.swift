import BentoCore
import BentoFixes
import SwiftUI

/// Modal Fix Preview sheet displaying planned `FileOp` operations, backup folder location,
/// a monospaced coloured unified diff viewer, and an `Apply` button gated by `"Allow changes"` (`PLAN.md` §6.6, §6.7).
struct FixPreviewSheet: View {
    let model: BentoAppModel
    let state: ActiveFixSheetState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(state.plan.kind.displayName, systemImage: "wand.and.stars")
                        .font(.title3.weight(.bold))
                    Text(state.plan.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(state.plan.agent.displayName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.blue.opacity(0.14)))
            }

            // Backup Directory & Read-Only Gate Notice
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "externaldrive.badge.timemachine")
                        .foregroundStyle(.teal)
                    Text("Backup location:")
                        .font(.caption.weight(.semibold))
                    Text(model.abbreviateHomePath(state.backupDirectoryPreviewPath))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if !model.allowChanges {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.orange)
                        Text("\"Allow changes\" is currently off. Enable it in Settings before applying fixes.")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Button("Enable in Settings…") {
                            model.dismissFixSheet()
                            model.selectedSection = .settings
                        }
                        .controlSize(.mini)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                }
            }

            // Planned FileOps
            GroupBox("Planned File Operations (\(state.plan.operations.count))") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(state.plan.operations.enumerated()), id: \.offset) { _, op in
                        HStack(spacing: 8) {
                            Image(systemName: op.symbolName)
                                .foregroundStyle(.blue)
                                .frame(width: 18)
                            Text(op.displayTitle)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Spacer()
                        }
                    }
                }
                .padding(.top, 4)
            }

            // Monospaced Coloured Unified Diff Viewer
            GroupBox("Unified Diff Preview (\(state.diffs.count) file(s))") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(state.diffs.enumerated()), id: \.offset) { _, diff in
                            UnifiedDiffBlockView(diff: diff, model: model)
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(minHeight: 240, maxHeight: 360)
            }

            HStack {
                Button("Cancel") {
                    model.dismissFixSheet()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Apply Fix") {
                    Task {
                        await model.applyActiveFixPlan()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canApplyActiveFix)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("fix-sheet-apply-button")
            }
        }
        .padding(20)
        .frame(minWidth: 740, idealWidth: 820, minHeight: 560)
    }
}

private struct UnifiedDiffBlockView: View {
    let diff: UnifiedDiff
    let model: BentoAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.abbreviateHomePath(diff.path))
                    .font(.caption.monospaced().weight(.semibold))
                Spacer()
                Text(diff.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            let lines = diff.patch.components(separatedBy: "\n")
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.caption.monospaced())
                        .foregroundStyle(foregroundColor(for: line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(backgroundColor(for: line))
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.04))
            )
        }
    }

    private func foregroundColor(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") {
            return .secondary
        }
        if line.hasPrefix("@@") {
            return .cyan
        }
        if line.hasPrefix("+") {
            return .green
        }
        if line.hasPrefix("-") {
            return .red
        }
        return .primary
    }

    private func backgroundColor(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") {
            return .clear
        }
        if line.hasPrefix("+") {
            return Color.green.opacity(0.12)
        }
        if line.hasPrefix("-") {
            return Color.red.opacity(0.12)
        }
        if line.hasPrefix("@@") {
            return Color.cyan.opacity(0.08)
        }
        return .clear
    }
}
