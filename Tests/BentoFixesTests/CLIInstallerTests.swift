import BentoCore
import BentoFixes
import Foundation
import Testing

struct CLIInstallerTests {
    @Test("CLIInstaller refuses install and uninstall without explicit user consent")
    func refusesInstallAndUninstallWithoutExplicitUserConsent() throws {
        let tempRoot = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fakeApp = try Self.makeFakeAppBundle(in: tempRoot)
        let installer = CLIInstaller(appBundleURL: fakeApp)
        let destinationDir = tempRoot.appendingPathComponent("home/.local/bin", isDirectory: true)
        let symlinkURL = destinationDir.appendingPathComponent(Product.cliName)

        #expect(throws: CLIInstallerError.consentRequired) {
            _ = try installer.install(
                to: symlinkURL,
                userConsented: false,
                pathEnvironment: "/usr/bin:/bin"
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destinationDir.path))
        #expect(installer.status(at: symlinkURL) == .notInstalled(destination: symlinkURL.standardizedFileURL))

        #expect(throws: CLIInstallerError.consentRequired) {
            try installer.uninstall(at: symlinkURL, userConsented: false)
        }
    }

    @Test("CLIInstaller creates parent bin directory, installs executable symlink, checks PATH, and uninstalls")
    func installsSymlinkCreatesParentDirRunsEmbeddedCLIAndChecksPATH() throws {
        let tempRoot = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fakeApp = try Self.makeFakeAppBundle(in: tempRoot)
        let expectedHelper = CLIInstaller.embeddedBinaryURL(inAppBundle: fakeApp)
        let installer = CLIInstaller(appBundleURL: fakeApp)
        #expect(installer.embeddedCLIBinaryURL()?.standardizedFileURL == expectedHelper.standardizedFileURL)

        let fakeHome = tempRoot.appendingPathComponent("home", isDirectory: true)
        let symlinkURL = CLIInstallDestinationPreset.userLocalBin.symlinkURL(homeDirectory: fakeHome)

        let resultNotOnPath = try installer.install(
            to: symlinkURL,
            userConsented: true,
            pathEnvironment: "/usr/bin:/bin"
        )
        #expect(resultNotOnPath.symlinkURL == symlinkURL.standardizedFileURL)
        #expect(resultNotOnPath.targetBinaryURL == expectedHelper.standardizedFileURL)
        #expect(resultNotOnPath.replacedExistingSymlink == false)
        #expect(resultNotOnPath.isDirectoryOnPATH == false)
        #expect(
            installer.status(at: symlinkURL)
                == .installedMatching(
                    destination: symlinkURL.standardizedFileURL,
                    target: expectedHelper.standardizedFileURL
                )
        )

        // Execute the CLI directly via the installed symlink.
        let process = Process()
        process.executableURL = symlinkURL
        process.arguments = ["--version"]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: outData, as: UTF8.self).contains(Product.version))

        // Re-installing when bin dir IS on PATH reports isDirectoryOnPATH == true and replacedExistingSymlink == true.
        let binDirPath = symlinkURL.deletingLastPathComponent().standardizedFileURL.path
        let resultOnPath = try installer.install(
            to: symlinkURL,
            userConsented: true,
            pathEnvironment: "/usr/bin:\(binDirPath):/bin"
        )
        #expect(resultOnPath.replacedExistingSymlink == true)
        #expect(resultOnPath.isDirectoryOnPATH == true)

        try installer.uninstall(at: symlinkURL, userConsented: true)
        #expect(installer.status(at: symlinkURL) == .notInstalled(destination: symlinkURL.standardizedFileURL))
    }

    @Test("CLIInstaller updates stale symlinks and refuses to clobber regular non-symlink files")
    func updatesStaleSymlinkAndNeverOverwritesRegularFile() throws {
        let tempRoot = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let oldApp = try Self.makeFakeAppBundle(in: tempRoot, bundleFolderName: "OldApp.app")
        let newApp = try Self.makeFakeAppBundle(in: tempRoot, bundleFolderName: "NewApp.app")
        let oldHelper = CLIInstaller.embeddedBinaryURL(inAppBundle: oldApp)
        let newHelper = CLIInstaller.embeddedBinaryURL(inAppBundle: newApp)

        let binDir = tempRoot.appendingPathComponent("usr-local-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let symlinkURL = binDir.appendingPathComponent(Product.cliName)
        try FileManager.default.createSymbolicLink(
            atPath: symlinkURL.path,
            withDestinationPath: oldHelper.path
        )

        let installer = CLIInstaller(appBundleURL: newApp)
        #expect(
            installer.status(at: symlinkURL)
                == .installedPointingElsewhere(
                    destination: symlinkURL.standardizedFileURL,
                    currentTarget: oldHelper.standardizedFileURL,
                    expectedTarget: newHelper.standardizedFileURL
                )
        )

        let updated = try installer.install(
            to: symlinkURL,
            userConsented: true,
            pathEnvironment: binDir.path
        )
        #expect(updated.replacedExistingSymlink == true)
        #expect(
            installer.status(at: symlinkURL)
                == .installedMatching(
                    destination: symlinkURL.standardizedFileURL,
                    target: newHelper.standardizedFileURL
                )
        )

        // Replace with a regular non-symlink file and verify install & uninstall both refuse to clobber it.
        try installer.uninstall(at: symlinkURL, userConsented: true)
        let regularPayload = Data("user-owned-script-do-not-overwrite".utf8)
        try regularPayload.write(to: symlinkURL)

        #expect(installer.status(at: symlinkURL) == .conflictRegularFile(destination: symlinkURL.standardizedFileURL))
        #expect(throws: CLIInstallerError.destinationIsRegularFile(symlinkURL.standardizedFileURL)) {
            _ = try installer.install(to: symlinkURL, userConsented: true, pathEnvironment: nil)
        }
        #expect(throws: CLIInstallerError.destinationIsRegularFile(symlinkURL.standardizedFileURL)) {
            try installer.uninstall(at: symlinkURL, userConsented: true)
        }
        #expect(try Data(contentsOf: symlinkURL) == regularPayload)
    }

    private static func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-cli-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeFakeAppBundle(
        in parentDir: URL,
        bundleFolderName: String = "\(Product.name).app"
    ) throws -> URL {
        let appURL = parentDir.appendingPathComponent(bundleFolderName, isDirectory: true)
        let helpersDir = appURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpersDir, withIntermediateDirectories: true)

        let helperURL = helpersDir.appendingPathComponent(Product.cliName, isDirectory: false)
        let script = """
            #!/bin/sh
            echo "\(Product.cliName) \(Product.version)"
            """
        try Data(script.utf8).write(to: helperURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: helperURL.path
        )
        return appURL
    }
}
