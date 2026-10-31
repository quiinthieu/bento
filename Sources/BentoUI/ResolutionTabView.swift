import BentoCore
import SwiftUI

/// Repository Detail → `Resolution` tab showing effective load order, scope badges,
/// struck-through shadowed artifacts with shadowing reasons, and Finder/Editor actions (`PLAN.md` §6.7).
struct ResolutionTabView: View {
    let model: BentoAppModel
    let repo: DiscoveredRepo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !model.selectedRepoAgent.supportsFullBudgetAndUsage {
                    InventoryOnlyResolutionFallbackView(model: model)
                } else if let resolution = model.currentRepoResolution {
                    if !resolution.warnings.isEmpty {
                        GroupBox("Resolution Warnings") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(resolution.warnings.enumerated()), id: \.offset) { _, warning in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: warning.severity.symbolName)
                                            .foregroundStyle(warning.severity.tintColor)
                                        Text(warning.message)
                                            .font(.caption)
                                        Spacer()
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                    }

                    // Active Load Order
                    GroupBox("Effective Load Order (\(resolution.ordered.count))") {
                        VStack(alignment: .leading, spacing: 0) {
                            if resolution.ordered.isEmpty {
                                Text(
                                    "No active artifacts resolved for \(model.selectedRepoAgent.displayName) in \(repo.displayName)."
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                            } else {
                                ForEach(Array(resolution.ordered.enumerated()), id: \.offset) { index, resolved in
                                    if let artifact = model.artifact(for: resolved.artifactID) {
                                        ActiveResolvedRowView(
                                            rank: index + 1,
                                            resolved: resolved,
                                            artifact: artifact,
                                            model: model
                                        )
                                        Divider()
                                    }
                                }
                            }
                        }
                    }

                    // Shadowed Items (Struck Through with Reason)
                    GroupBox("Shadowed / Overridden Artifacts (\(resolution.shadowed.count))") {
                        VStack(alignment: .leading, spacing: 0) {
                            if resolution.shadowed.isEmpty {
                                Text("No shadowed or overridden artifacts for \(model.selectedRepoAgent.displayName).")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 8)
                            } else {
                                ForEach(Array(resolution.shadowed.enumerated()), id: \.offset) { _, shadow in
                                    ShadowedArtifactRowView(shadow: shadow, model: model)
                                    Divider()
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Resolution Available",
                        systemImage: "list.number",
                        description: Text("Rescan workspace (⌘R) to compute load precedence.")
                    )
                }
            }
            .padding(16)
        }
    }
}

private struct ActiveResolvedRowView: View {
    let rank: Int
    let resolved: ResolvedArtifact
    let artifact: Artifact
    let model: BentoAppModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("#\(rank)")
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Button {
                        model.inspectorSelection = .artifact(artifact.id)
                    } label: {
                        Text(artifact.name)
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)

                    ScopeBadgeView(scope: artifact.scope)

                    Text(artifact.kind.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))

                    Text(resolved.effectiveLoadMode.displayLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(model.abbreviateHomePath(artifact.location.path))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                if !resolved.reason.isEmpty {
                    Text(resolved.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Button("Reveal in Finder") {
                    model.revealArtifactInFinder(artifact)
                }
                .controlSize(.small)

                Button("Open in editor") {
                    model.openArtifactInEditor(artifact)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
    }
}

private struct ShadowedArtifactRowView: View {
    let shadow: ShadowRecord
    let model: BentoAppModel

    var body: some View {
        let shadowedArtifact = model.artifact(for: shadow.shadowedArtifactID)
        let winningArtifact = model.artifact(for: shadow.winningArtifactID)

        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(shadowedArtifact?.name ?? shadow.shadowedArtifactID.rawValue)
                        .font(.subheadline.weight(.medium))
                        .strikethrough(true, color: .secondary)
                        .foregroundStyle(.secondary)

                    if let scope = shadowedArtifact?.scope {
                        ScopeBadgeView(scope: scope)
                    }
                }

                if let path = shadowedArtifact?.location.path {
                    Text(model.abbreviateHomePath(path))
                        .font(.caption.monospaced())
                        .strikethrough(true, color: .secondary)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Text("Shadowed:")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(shadow.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let winner = winningArtifact {
                        Text("(winner: \(winner.name) [\(winner.scope.badgeTitle)])")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if let artifact = shadowedArtifact {
                HStack(spacing: 6) {
                    Button("Reveal in Finder") {
                        model.revealArtifactInFinder(artifact)
                    }
                    .controlSize(.small)

                    Button("Open in editor") {
                        model.openArtifactInEditor(artifact)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
    }
}

private struct InventoryOnlyResolutionFallbackView: View {
    let model: BentoAppModel

    var body: some View {
        let artifacts = model.currentRepoArtifactsForSelectedAgent
        GroupBox("Discovered \(model.selectedRepoAgent.displayName) Artifacts (\(artifacts.count))") {
            VStack(alignment: .leading, spacing: 0) {
                if artifacts.isEmpty {
                    Text("No \(model.selectedRepoAgent.displayName) artifacts discovered for this repository.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(artifacts) { artifact in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(artifact.name)
                                        .font(.subheadline.weight(.semibold))
                                    ScopeBadgeView(scope: artifact.scope)
                                    Text(artifact.kind.displayName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(model.abbreviateHomePath(artifact.location.path))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Reveal in Finder") {
                                model.revealArtifactInFinder(artifact)
                            }
                            .controlSize(.small)
                            Button("Open in editor") {
                                model.openArtifactInEditor(artifact)
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 8)
                        Divider()
                    }
                }
            }
        }
    }
}
