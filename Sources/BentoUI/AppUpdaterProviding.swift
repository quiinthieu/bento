import Foundation

/// Protocol abstracting application update checks (`sparkle-project/Sparkle` in the packaged macOS app)
/// so update checks can be turned completely off by the user (`PLAN.md` §0 Rule 5, §7, §11 T16).
@MainActor
public protocol AppUpdaterProviding: AnyObject {
    /// Whether an updater engine (Sparkle EdDSA) is configured and available in this runtime bundle.
    var isUpdaterAvailable: Bool { get }

    /// Whether automatic background update checks are currently enabled.
    var automaticallyChecksForUpdates: Bool { get }

    /// Whether a manual `"Check for Updates…"` request can currently be triggered.
    var canCheckForUpdates: Bool { get }

    /// Configured Sparkle appcast feed URL string, if present.
    var feedURLString: String? { get }

    /// Enables or turns off automatic background update checks.
    func setAutomaticallyChecksForUpdates(_ enabled: Bool)

    /// Triggers an explicit user-initiated update check.
    func checkForUpdates()
}

/// Default no-op updater used when running from SwiftPM development builds, CLI tests, or when Sparkle is disabled.
@MainActor
public final class DisabledAppUpdater: AppUpdaterProviding {
    public let isUpdaterAvailable: Bool = false
    public private(set) var automaticallyChecksForUpdates: Bool = false
    public let canCheckForUpdates: Bool = false
    public let feedURLString: String? = nil

    public init() {}

    public func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        automaticallyChecksForUpdates = false
    }

    public func checkForUpdates() {}
}
