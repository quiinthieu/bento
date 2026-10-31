import BentoCore
import SwiftUI

/// First-run privacy & permissions onboarding sheet (`PLAN.md` §7).
struct OnboardingSheet: View {
    let model: BentoAppModel

    var body: some View {
        let copy = OnboardingCopy.make(productName: model.effectiveProductName)

        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(copy.title)
                    .font(.title2.weight(.bold))
                Text(copy.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            OnboardingPointRow(
                symbolName: "lock.shield.fill",
                tint: .green,
                heading: "100% Local & Zero Telemetry",
                detail: copy.localOnlyStatement
            )

            OnboardingPointRow(
                symbolName: "folder.badge.person.crop",
                tint: .blue,
                heading: "Why Full Disk Access Is Not Required",
                detail: copy.fullDiskAccessExplanation
            )

            OnboardingPointRow(
                symbolName: "hand.raised.square.fill",
                tint: .orange,
                heading: "Explicit Consent for MCP Server Probes",
                detail: copy.mcpProbeConsentStatement
            )

            OnboardingPointRow(
                symbolName: "arrow.uturn.backward.circle.fill",
                tint: .teal,
                heading: "Read-Only Default & Reversible Diffs",
                detail: copy.readOnlyDefaultStatement
            )

            HStack {
                Spacer()
                Button("Continue in Read-Only Mode") {
                    model.completeOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding-continue-button")
            }
        }
        .padding(24)
        .frame(width: 640)
    }
}

private struct OnboardingPointRow: View {
    let symbolName: String
    let tint: Color
    let heading: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(heading)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Modal request preview shown before sending artifact text (never logs) to Anthropic or Gemini token-count APIs (`PLAN.md` §7, §11 T15).
struct TokenCountPreviewSheet: View {
    let model: BentoAppModel
    let preview: TokenCountRequestPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Exact Token-Count API Request Preview", systemImage: "network.badge.shield.half.filled")
                    .font(.title3.weight(.bold))
                Text(
                    "Review the exact HTTP payload(s) for \(preview.provider.displayName) in \(model.abbreviateHomePath(preview.repoPath)). "
                        + "Only discovered configuration artifact text is sent — session logs and credentials are never included."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if preview.items.isEmpty {
                        Text(
                            "No non-empty text artifacts resolved for \(preview.agent.displayName) in this repository."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                    } else {
                        ForEach(preview.items) { item in
                            GroupBox("\(item.label) (\(item.kind.displayName))") {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(item.httpMethod) \(item.endpointURL)")
                                        .font(.caption.monospaced().weight(.semibold))
                                        .textSelection(.enabled)

                                    VStack(alignment: .leading, spacing: 2) {
                                        ForEach(item.redactedHeaders.keys.sorted(), id: \.self) { header in
                                            Text("\(header): \(item.redactedHeaders[header] ?? "")")
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Text(item.httpBodyPreview)
                                        .font(.caption2.monospaced())
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color.primary.opacity(0.04))
                                        )
                                        .textSelection(.enabled)
                                }
                                .padding(.top, 4)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 280, maxHeight: 420)

            HStack {
                Button("Cancel") {
                    model.activeTokenCountPreview = nil
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    model.isSendingTokenCountPreview = true
                    Task {
                        defer { model.isSendingTokenCountPreview = false }
                        do {
                            try await model.confirmAndRunExactTokenCount(preview: preview)
                        } catch {
                            model.lastErrorMessage = error.localizedDescription
                        }
                    }
                } label: {
                    if model.isSendingTokenCountPreview {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Send \(preview.items.count) Request(s) & Mark Exact")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSendingTokenCountPreview || preview.items.isEmpty)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("confirm-exact-token-count-button")
            }
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 780, minHeight: 500)
    }
}
