import BentoCore
import BentoFixes
import BentoStore
import BentoTestSupport
import Foundation
import Testing

@testable import BentoUI

@MainActor
private final class SpyAppUpdater: AppUpdaterProviding {
    var isUpdaterAvailable: Bool = true
    var automaticallyChecksForUpdates: Bool = false
    var canCheckForUpdates: Bool = true
    var feedURLString: String? = "https://github.com/quiinthieu/bento/releases/latest/download/appcast.xml"

    var setAutoCalls: [Bool] = []
    var checkCalls: Int = 0

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        automaticallyChecksForUpdates = enabled
        setAutoCalls.append(enabled)
    }

    func checkForUpdates() {
        checkCalls += 1
    }
}

@MainActor
struct ReleaseAndUpdaterUITests {
    @Test("Automatic update checks default to off, can be enabled and turned off, and persist in BentoStore")
    func updaterToggleCanTurnOffSparkleAndPersistsSetting() throws {
        let baseFixture = try FixtureHome(scenario: "empty")
        let tempHome = try baseFixture.copyToTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let env = AgentEnvironment(
            home: tempHome,
            env: ["BENTO_SYSTEM_ROOT": tempHome.path, "HOME": tempHome.path],
            fileSystem: LocalReadOnlyFileSystem(),
            now: { FixtureHome.defaultTimestamp }
        )

        let store = try BentoStore.inMemory()
        let supportDir = tempHome.appendingPathComponent("Support", isDirectory: true)
        let fixEngine = FixEngine(
            homeURL: tempHome,
            supportDirectory: supportDir,
            store: store,
            fileSystem: env.fileSystem
        )
        let updater = SpyAppUpdater()

        let model = BentoAppModel(
            environment: env,
            store: store,
            supportDirectory: supportDir,
            fixEngine: fixEngine,
            apiKeyStore: InMemoryAPIKeyStore(),
            updater: updater
        )

        // Off by default (no unsolicited background network requests).
        #expect(model.automaticallyChecksForUpdates == false)
        #expect(updater.automaticallyChecksForUpdates == false)

        // Enable automatic checks.
        try model.setAutomaticallyChecksForUpdates(true)
        #expect(model.automaticallyChecksForUpdates == true)
        #expect(updater.automaticallyChecksForUpdates == true)
        #expect(updater.setAutoCalls.last == true)

        // Trigger explicit user check.
        model.checkForUpdates()
        #expect(updater.checkCalls == 1)

        // Turn automatic checks off (`PLAN.md` §7, §11 T16: Sparkle can be turned off).
        try model.setAutomaticallyChecksForUpdates(false)
        #expect(model.automaticallyChecksForUpdates == false)
        #expect(updater.automaticallyChecksForUpdates == false)
        #expect(updater.setAutoCalls.last == false)

        // Reloading a second model from the same store restores the persisted setting.
        let reloadedUpdater = SpyAppUpdater()
        reloadedUpdater.automaticallyChecksForUpdates = true
        let reloadedModel = BentoAppModel(
            environment: env,
            store: store,
            supportDirectory: supportDir,
            fixEngine: fixEngine,
            apiKeyStore: InMemoryAPIKeyStore(),
            updater: reloadedUpdater
        )
        #expect(reloadedModel.automaticallyChecksForUpdates == false)
        #expect(reloadedUpdater.automaticallyChecksForUpdates == false)
    }

    @Test("Install CLI flow requires explicit user confirmation before creating symlink in hermetic home")
    func installCLIFromAppModelRequiresConsentConfirmationAndInstallsIntoHermeticHome() throws {
        let baseFixture = try FixtureHome(scenario: "empty")
        let tempHome = try baseFixture.copyToTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let env = AgentEnvironment(
            home: tempHome,
            env: ["BENTO_SYSTEM_ROOT": tempHome.path, "HOME": tempHome.path],
            fileSystem: LocalReadOnlyFileSystem(),
            now: { FixtureHome.defaultTimestamp }
        )

        let fakeApp = tempHome.appendingPathComponent("FakeBundle/\(Product.name).app", isDirectory: true)
        let helpersDir = fakeApp.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpersDir, withIntermediateDirectories: true)
        let helperBinary = helpersDir.appendingPathComponent(Product.cliName)
        try Data("#!/bin/sh\necho ok\n".utf8).write(to: helperBinary)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: helperBinary.path
        )

        let store = try BentoStore.inMemory()
        let supportDir = tempHome.appendingPathComponent("Support", isDirectory: true)
        let fixEngine = FixEngine(
            homeURL: tempHome,
            supportDirectory: supportDir,
            store: store,
            fileSystem: env.fileSystem
        )
        let installer = CLIInstaller(appBundleURL: fakeApp)

        let model = BentoAppModel(
            environment: env,
            store: store,
            supportDirectory: supportDir,
            fixEngine: fixEngine,
            apiKeyStore: InMemoryAPIKeyStore(),
            cliInstaller: installer
        )

        let expectedSymlink =
            tempHome
            .appendingPathComponent(".local/bin", isDirectory: true)
            .appendingPathComponent(Product.cliName)
            .standardizedFileURL

        #expect(model.currentCLISymlinkURL() == expectedSymlink)
        #expect(model.currentCLIInstallStatus() == .notInstalled(destination: expectedSymlink))

        // Requesting install ONLY opens the consent sheet — zero writes on disk!
        model.requestInstallCLI(preset: .userLocalBin)
        #expect(model.isShowingInstallCLIConfirmation == true)
        #expect(!FileManager.default.fileExists(atPath: expectedSymlink.path))
        #expect(model.currentCLIInstallStatus() == .notInstalled(destination: expectedSymlink))

        // Confirming install performs the consented symlink creation.
        let result = try model.confirmInstallCLI()
        #expect(model.isShowingInstallCLIConfirmation == false)
        #expect(result.symlinkURL == expectedSymlink)
        #expect(
            model.currentCLIInstallStatus()
                == .installedMatching(
                    destination: expectedSymlink,
                    target: helperBinary.standardizedFileURL
                )
        )

        // Consented removal cleans up the symlink.
        try model.uninstallCLISymlink(userConsented: true)
        #expect(model.currentCLIInstallStatus() == .notInstalled(destination: expectedSymlink))
    }
}
