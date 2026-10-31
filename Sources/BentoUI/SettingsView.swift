import BentoCore
import BentoFixes
import SwiftUI

/// Sidebar → `Settings` view managing `"Allow changes"`, repository roots, log retention,
/// unused thresholds, Keychain API keys, MCP probe consents, canonical skills dir,
/// `#if DEBUG` product name override, and `"Delete all <Product.name> data"` (`PLAN.md` §6.7, §7).
struct SettingsView: View {
    let model: BentoAppModel

    var body: some View {
        @Bindable var bindableModel = model
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings")
                    .font(.title2.weight(.bold))

                // 1. Master Safety Gate
                GroupBox("Configuration Editing Safety Gate") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(
                            isOn: Binding(
                                get: { model.allowChanges },
                                set: { enabled in
                                    do {
                                        try model.setAllowChanges(enabled)
                                    } catch {
                                        model.lastErrorMessage = error.localizedDescription
                                    }
                                }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Allow changes to agent configuration files")
                                    .font(.subheadline.weight(.semibold))
                                Text(
                                    "Off by default. When off, \(model.effectiveProductName) operates strictly read-only and disables Apply and Undo actions."
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("settings-allow-changes-toggle")

                        Divider()

                        HStack {
                            Text("Canonical consolidated skills directory:")
                                .font(.caption.weight(.medium))
                            TextField("~/.agents/skills (default)", text: $bindableModel.canonicalSkillsDirectory)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption.monospaced())
                        }
                    }
                    .padding(.top, 4)
                }

                // 2. Repository Discovery & Roots
                GroupBox("Repository Discovery & Workspace Roots") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(
                            "Shallow-scan home workspace roots (depth ≤ 3, .git present)",
                            isOn: $bindableModel.includeShallowScan
                        )
                        .font(.subheadline)

                        HStack {
                            Text("Home-relative roots:")
                                .font(.caption.weight(.medium))
                            TextField("Developer, code, src, Projects", text: $bindableModel.shallowScanRootsText)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption.monospaced())
                        }

                        Divider()

                        Text("Manually added repository paths:")
                            .font(.caption.weight(.semibold))

                        HStack {
                            TextField("/path/to/repository", text: $bindableModel.settingsManualRepoDraft)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption.monospaced())
                            Button("Add Folder") {
                                let trimmed = model.settingsManualRepoDraft.trimmingCharacters(
                                    in: .whitespacesAndNewlines)
                                guard !trimmed.isEmpty else { return }
                                model.settingsManualRepoDraft = ""
                                Task {
                                    try? await model.addManualRepository(path: trimmed)
                                }
                            }
                            .disabled(
                                model.settingsManualRepoDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        ForEach(model.manualRepoPaths, id: \.self) { path in
                            HStack {
                                Text(model.abbreviateHomePath(path))
                                    .font(.caption.monospaced())
                                Spacer()
                                Button("Remove") {
                                    Task {
                                        try? await model.removeManualRepository(path: path)
                                    }
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .foregroundStyle(.red)
                            }
                        }
                    }
                    .padding(.top, 4)
                }

                // 3. Log Retention & Unused Thresholds
                GroupBox("Usage Retention & Unused Artifact Thresholds") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 16) {
                            Stepper(
                                "Usage event retention: \(model.retentionDays) days",
                                value: $bindableModel.retentionDays,
                                in: 7...730,
                                step: 15
                            )
                            Spacer()
                            Button("Prune Expired Events Now") {
                                do {
                                    _ = try model.pruneOldUsageEventsNow()
                                } catch {
                                    model.lastErrorMessage = error.localizedDescription
                                }
                            }
                            .controlSize(.small)
                        }

                        HStack(spacing: 24) {
                            Stepper(
                                "Unused lookback window: \(model.unusedWindowDays) days",
                                value: $bindableModel.unusedWindowDays,
                                in: 1...365
                            )

                            Stepper(
                                "Minimum repo sessions before flagging unused: \(model.unusedMinimumSessions)",
                                value: $bindableModel.unusedMinimumSessions,
                                in: 1...100
                            )
                        }

                        HStack {
                            Spacer()
                            Button("Save Discovery & Threshold Settings") {
                                Task {
                                    await model.saveSettingsAndRefresh()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding(.top, 4)
                }

                // 4. Opt-in Token-Count APIs & Keychain API Keys
                GroupBox("Opt-in Exact Token-Count APIs (Keychain Only)") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(
                            "API keys are stored exclusively in the macOS Keychain — never in SQLite, logs, or files. "
                                + "Enabling an API always shows a per-request preview containing artifact text only (never session logs) before sending."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        APIProviderSettingsRow(
                            provider: .anthropic,
                            keyInput: $bindableModel.settingsAnthropicKeyDraft,
                            model: model
                        )

                        Divider()

                        APIProviderSettingsRow(
                            provider: .gemini,
                            keyInput: $bindableModel.settingsGeminiKeyDraft,
                            model: model
                        )
                    }
                    .padding(.top, 4)
                }

                // 5. MCP Probe Consents
                GroupBox("MCP Server Probe Consents") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.shield.fill")
                                .foregroundStyle(.orange)
                            Text(
                                "Probing an MCP server executes third-party commands or connects to external endpoints. "
                                    + "\(model.effectiveProductName) runs probes with explicit per-server consent (keyed by config hash), "
                                    + "a scrubbed environment, a 15-second timeout, and no TTY."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        if model.mcpServerEntries.isEmpty {
                            Text("No MCP servers discovered in current workspace snapshot.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.mcpServerEntries) { entry in
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(entry.serverName)
                                                .font(.subheadline.weight(.semibold))
                                            Text(entry.agent.shortDisplayName)
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                                            ScopeBadgeView(scope: entry.artifact.scope)
                                        }
                                        Text("Config hash: \(entry.configHash.prefix(16))…")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                        if let probe = entry.cachedProbe {
                                            Text(
                                                probe.ok
                                                    ? "Probed \(probe.tools.count) tool(s) (~\(probe.toolsTokensEstimate) tokens)"
                                                    : "Last probe failed: \(probe.error ?? "unknown error")"
                                            )
                                            .font(.caption2)
                                            .foregroundStyle(probe.ok ? .green : .red)
                                        }
                                    }

                                    Spacer()

                                    if entry.hasConsent {
                                        Button("Re-Probe") {
                                            Task {
                                                await model.grantMCPConsentAndProbe(entry)
                                            }
                                        }
                                        .controlSize(.small)

                                        Button("Revoke Consent") {
                                            model.revokeMCPConsent(forHash: entry.configHash)
                                        }
                                        .controlSize(.small)
                                        .foregroundStyle(.red)
                                    } else {
                                        Button("Grant Consent & Probe") {
                                            Task {
                                                await model.grantMCPConsentAndProbe(entry)
                                            }
                                        }
                                        .controlSize(.small)
                                    }
                                }
                                .padding(.vertical, 4)
                                Divider()
                            }

                            HStack {
                                Spacer()
                                Button("Revoke All MCP Consents") {
                                    model.revokeAllMCPConsents()
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(.top, 4)
                }

                #if DEBUG
                    GroupBox("Developer Build Overrides (DEBUG Only)") {
                        HStack {
                            Text("Product display name override:")
                                .font(.caption.weight(.medium))
                            TextField(Product.name, text: $bindableModel.debugProductNameOverride)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 260)
                            Button("Apply") {
                                Task {
                                    await model.saveSettingsAndRefresh()
                                }
                            }
                            .controlSize(.small)
                        }
                        .padding(.top, 4)
                    }
                #endif

                // 6. Companion CLI Installer (PLAN.md §11 T16)
                GroupBox("Command Line Tool (\(Product.cliName))") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(
                            "\(model.effectiveProductName) embeds \(Product.cliName) inside \(Product.name).app/Contents/Helpers/\(Product.cliName). "
                                + "With your explicit consent, install a symlink into ~/.local/bin or /usr/local/bin."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Picker("Install destination:", selection: $bindableModel.selectedCLIInstallPreset) {
                            Text("~/.local/bin/\(Product.cliName) (Recommended)")
                                .tag(CLIInstallDestinationPreset.userLocalBin)
                            Text("/usr/local/bin/\(Product.cliName)")
                                .tag(CLIInstallDestinationPreset.usrLocalBin)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 520)

                        CLIInstallStatusRow(model: model)
                    }
                    .padding(.top, 4)
                }

                // 7. Application Updates — Sparkle EdDSA (can be turned off; PLAN.md §0 Rule 5, §7, §11 T16)
                GroupBox("Application Updates (Sparkle EdDSA)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(
                            isOn: Binding(
                                get: { model.automaticallyChecksForUpdates },
                                set: { enabled in
                                    do {
                                        try model.setAutomaticallyChecksForUpdates(enabled)
                                    } catch {
                                        model.lastErrorMessage = error.localizedDescription
                                    }
                                }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Automatically check for updates")
                                    .font(.subheadline.weight(.semibold))
                                Text(
                                    "Off by default and can be turned off at any time. When off, zero Sparkle update network requests are made."
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("settings-automatic-updates-toggle")

                        HStack {
                            if let feed = model.updaterFeedURLString {
                                Text("Appcast feed: \(feed)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            } else if !model.isUpdaterAvailable {
                                Text("Sparkle updater is inactive in unsigned/development builds.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Check for Updates…") {
                                model.checkForUpdates()
                            }
                            .controlSize(.small)
                            .disabled(!model.isUpdaterAvailable || !model.canCheckForUpdates)
                        }
                    }
                    .padding(.top, 4)
                }

                // 8. Privacy & Delete All Data
                GroupBox("Privacy & Local Data Reset") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Delete all \(model.effectiveProductName) data")
                                .font(.subheadline.weight(.semibold))
                            Text(
                                "Wipes snapshots, usage counters, calibrations, MCP probe caches, fix journal rows, and settings from local SQLite."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Delete all \(model.effectiveProductName) data…", role: .destructive) {
                            model.isConfirmingDeleteAllData = true
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(20)
        }
        .confirmationDialog(
            "Delete all \(model.effectiveProductName) data?",
            isPresented: $bindableModel.isConfirmingDeleteAllData
        ) {
            Button("Delete Local Database Only", role: .destructive) {
                Task {
                    try? await model.deleteAllProductData(includeAPIKeys: false)
                }
            }
            Button("Delete Database & Keychain API Keys", role: .destructive) {
                Task {
                    try? await model.deleteAllProductData(includeAPIKeys: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Agent configuration files in your home folder and repositories will never be modified or deleted by this action."
            )
        }
    }
}

private struct APIProviderSettingsRow: View {
    let provider: TokenCountAPIProviderID
    @Binding var keyInput: String
    let model: BentoAppModel

    var body: some View {
        let isEnabled = model.isTokenCountAPIEnabled(for: provider)
        let hasKey = model.hasStoredAPIKey(for: provider)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(
                    isOn: Binding(
                        get: { isEnabled },
                        set: { newValue in
                            do {
                                try model.setTokenCountAPIEnabled(newValue, for: provider)
                            } catch {
                                model.lastErrorMessage = error.localizedDescription
                            }
                        }
                    )
                ) {
                    HStack(spacing: 8) {
                        Text(provider.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text(hasKey ? "Key Stored in Keychain" : "No Key Stored")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(hasKey ? .green : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(hasKey ? Color.green.opacity(0.14) : Color.secondary.opacity(0.12))
                            )
                    }
                }

                Spacer()

                if isEnabled && hasKey {
                    Button("Preview Request…") {
                        Task {
                            do {
                                _ = try await model.prepareExactTokenCountPreview(for: provider)
                            } catch {
                                model.lastErrorMessage = error.localizedDescription
                            }
                        }
                    }
                    .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                SecureField("Paste \(provider.rawValue) API key (stored in Keychain only)", text: $keyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())

                Button("Save Key") {
                    let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    do {
                        try model.saveAPIKey(trimmed, for: provider)
                        keyInput = ""
                    } catch {
                        model.lastErrorMessage = error.localizedDescription
                    }
                }
                .controlSize(.small)
                .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if hasKey {
                    Button("Clear Key") {
                        do {
                            try model.saveAPIKey(nil, for: provider)
                        } catch {
                            model.lastErrorMessage = error.localizedDescription
                        }
                    }
                    .controlSize(.small)
                    .foregroundStyle(.red)
                }
            }
        }
    }
}

private struct CLIInstallStatusRow: View {
    let model: BentoAppModel

    var body: some View {
        let status = model.currentCLIInstallStatus()
        let embeddedURL = model.embeddedCLIBinaryURL

        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                switch status {
                case .notInstalled(let dest):
                    Text("Not installed at \(model.abbreviateHomePath(dest.path))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                case .installedMatching(let dest, let target):
                    Text("Installed: \(model.abbreviateHomePath(dest.path)) → \(target.path)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.green)

                case .installedPointingElsewhere(let dest, let currentTarget, _):
                    Text(
                        "Symlink at \(model.abbreviateHomePath(dest.path)) currently points to \(currentTarget.path)"
                    )
                    .font(.caption.monospaced())
                    .foregroundStyle(.orange)

                case .conflictRegularFile(let dest):
                    Text("Regular file exists at \(model.abbreviateHomePath(dest.path)) (will not be overwritten)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if embeddedURL == nil {
                    Text(
                        "Running from an unpackaged build — package \(Product.name).app via Scripts/make-dmg.sh to embed Contents/Helpers/\(Product.cliName)."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            switch status {
            case .installedMatching:
                Button("Remove Symlink") {
                    _ = try? model.uninstallCLISymlink(userConsented: true)
                }
                .controlSize(.small)
                .foregroundStyle(.red)

            case .installedPointingElsewhere:
                Button("Update Symlink…") {
                    model.requestInstallCLI()
                }
                .controlSize(.small)
                .disabled(embeddedURL == nil)

                Button("Remove Symlink") {
                    _ = try? model.uninstallCLISymlink(userConsented: true)
                }
                .controlSize(.small)
                .foregroundStyle(.red)

            case .notInstalled:
                Button("Install \(Product.cliName)…") {
                    model.requestInstallCLI()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(embeddedURL == nil)

            case .conflictRegularFile:
                Button("Install \(Product.cliName)…") {
                    model.requestInstallCLI()
                }
                .controlSize(.small)
                .disabled(true)
            }
        }
    }
}
