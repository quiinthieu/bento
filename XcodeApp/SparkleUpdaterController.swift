import BentoUI
import Foundation
import Sparkle

/// Sparkle 2 EdDSA updater adapter for the Xcode macOS `.app` target (`PLAN.md` §3.3, §7, §11 T16).
///
/// Honors `BENTO_DISABLE_SPARKLE=1`, `BentoEnableSparkle` Info.plist flag, `-fixtureHome` test launches,
/// and user opt-out in Settings so background Sparkle network requests never run when turned off
/// or when no EdDSA `SUPublicEDKey` is embedded (e.g. local ad-hoc builds).
@MainActor
final class SparkleUpdaterController: AppUpdaterProviding {
    private let controller: SPUStandardUpdaterController?
    private var didStartUpdater = false
    private let configuredFeedURL: String?

    init(bundle: Bundle = .main) {
        let env = ProcessInfo.processInfo.environment
        let envDisabled = env["BENTO_DISABLE_SPARKLE"] == "1"
        let isFixtureLaunch = CommandLine.arguments.contains("-fixtureHome")
        let plistEnabledRaw = (bundle.object(forInfoDictionaryKey: "BentoEnableSparkle") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let plistDisabled = (plistEnabledRaw == "NO" || plistEnabledRaw == "FALSE" || plistEnabledRaw == "0")
        let publicEDKey =
            (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let feedURL = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        self.configuredFeedURL = (feedURL?.isEmpty == false) ? feedURL : nil

        if envDisabled || isFixtureLaunch || plistDisabled || publicEDKey.isEmpty {
            self.controller = nil
        } else {
            self.controller = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            // Keep automatic background checks off until BentoAppModel applies the persisted user preference.
            self.controller?.updater.automaticallyChecksForUpdates = false
        }
    }

    var isUpdaterAvailable: Bool {
        controller != nil
    }

    var automaticallyChecksForUpdates: Bool {
        guard let controller, didStartUpdater else { return false }
        return controller.updater.automaticallyChecksForUpdates
    }

    var canCheckForUpdates: Bool {
        guard let controller else { return false }
        if !didStartUpdater {
            return true
        }
        return controller.updater.canCheckForUpdates
    }

    var feedURLString: String? {
        if let url = controller?.updater.feedURL?.absoluteString, !url.isEmpty {
            return url
        }
        return configuredFeedURL
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let controller else { return }
        if enabled {
            startUpdaterIfNeeded(controller)
            controller.updater.automaticallyChecksForUpdates = true
        } else {
            controller.updater.automaticallyChecksForUpdates = false
        }
    }

    func checkForUpdates() {
        guard let controller else { return }
        startUpdaterIfNeeded(controller)
        controller.checkForUpdates(nil)
    }

    private func startUpdaterIfNeeded(_ controller: SPUStandardUpdaterController) {
        guard !didStartUpdater else { return }
        do {
            try controller.updater.start()
            didStartUpdater = true
        } catch {
            didStartUpdater = false
        }
    }
}
