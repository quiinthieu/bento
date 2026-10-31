import BentoCore
import BentoFixes
import SwiftUI

/// Sidebar → `Agents` view detailing detection state, capabilities, and discovered artifacts per coding agent (`PLAN.md` §5, §6.7).
struct AgentsView: View {
    let model: BentoAppModel

    private var visibleAgents: [AgentID] {
        if let selectedAgentFilter = model.agentsFilter {
            return [selectedAgentFilter]
        }
        return AgentID.allCases
    }

    var body: some View {
        @Bindable var bindableModel = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Coding Agents Inventory")
                            .font(.title2.weight(.bold))
                        Text("Discovered user, project, local, and managed configuration artifacts")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Agent", selection: $bindableModel.agentsFilter) {
                        Text("All Agents").tag(AgentID?.none)
                        ForEach(AgentID.allCases, id: \.self) { agent in
                            Text(agent.displayName).tag(AgentID?.some(agent))
                        }
                    }
                    .frame(width: 200)
                }

                ForEach(visibleAgents, id: \.self) { agent in
                    AgentInventoryCard(agent: agent, model: model)
                }
            }
            .padding(20)
        }
    }
}

private struct AgentInventoryCard: View {
    let agent: AgentID
    let model: BentoAppModel

    var body: some View {
        let detection = model.snapshot?.detections[agent]
        let isDetected = detection?.isDetected ?? false
        let artifacts = model.artifacts(for: agent)

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let detectedPaths = detection?.detectedPaths, !detectedPaths.isEmpty {
                    Text(
                        "Detected roots: " + detectedPaths.map { model.abbreviateHomePath($0) }.joined(separator: ", ")
                    )
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                }

                if artifacts.isEmpty {
                    Text("No configuration artifacts discovered for \(agent.displayName).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(artifacts) { artifact in
                            HStack(spacing: 10) {
                                Button {
                                    model.inspectorSelection = .artifact(artifact.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(artifact.name)
                                                .font(.subheadline.weight(.medium))
                                            ScopeBadgeView(scope: artifact.scope)
                                            Text(artifact.kind.displayName)
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                                            if !artifact.enabled {
                                                Text("Disabled")
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundStyle(.orange)
                                            }
                                        }
                                        Text(model.abbreviateHomePath(artifact.location.path))
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                Button {
                                    model.revealArtifactInFinder(artifact)
                                } label: {
                                    Image(systemName: "folder")
                                }
                                .buttonStyle(.borderless)
                                .help("Reveal in Finder")

                                Button {
                                    model.openArtifactInEditor(artifact)
                                } label: {
                                    Image(systemName: "square.and.pencil")
                                }
                                .buttonStyle(.borderless)
                                .help("Open in editor")

                                if let fixKind = toggleFixKind(for: artifact) {
                                    Button(fixKind.displayName) {
                                        do {
                                            try model.openFixPreview(for: FixRequest(kind: fixKind, artifact: artifact))
                                        } catch {
                                            model.lastErrorMessage = error.localizedDescription
                                        }
                                    }
                                    .controlSize(.mini)
                                }
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: agent.symbolName)
                    .foregroundStyle(isDetected ? .blue : .secondary)
                Text(agent.displayName)
                    .font(.headline)
                Text(isDetected ? "Detected" : "Not Detected")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isDetected ? .green : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(isDetected ? Color.green.opacity(0.14) : Color.secondary.opacity(0.12))
                    )
                Text(agent.supportsFullBudgetAndUsage ? "Full Audit" : "Inventory + Hygiene")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(artifacts.count) artifact(s)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func toggleFixKind(for artifact: Artifact) -> FixKind? {
        guard artifact.scope != .managed, artifact.scope != .builtIn else { return nil }
        let support = model.workspace.fixSupport(for: artifact.agent)
        switch artifact.kind {
        case .mcpServer:
            if artifact.enabled && support.supportedKinds.contains(.disableMCPServer) {
                return .disableMCPServer
            }
            if !artifact.enabled && support.supportedKinds.contains(.enableMCPServer) {
                return .enableMCPServer
            }
            return nil
        case .skill:
            if artifact.enabled && support.supportedKinds.contains(.disableSkill) {
                return .disableSkill
            }
            return nil
        default:
            return nil
        }
    }
}
