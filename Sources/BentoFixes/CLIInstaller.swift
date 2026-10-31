import BentoCore
import Darwin
import Foundation

/// Standard destination presets for symlinking the embedded companion CLI (`PLAN.md` §11 T16).
public enum CLIInstallDestinationPreset: String, CaseIterable, Sendable, Identifiable {
    /// User-local `~/.local/bin/<Product.cliName>` (recommended; requires no administrator privileges).
    case userLocalBin
    /// System-wide `/usr/local/bin/<Product.cliName>` (when `/usr/local/bin` is writable by the current user).
    case usrLocalBin

    public var id: String { rawValue }

    /// Resolves the full destination symlink URL for this preset.
    public func symlinkURL(
        homeDirectory: URL,
        usrLocalBinDirectory: URL = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        cliName: String = Product.cliName
    ) -> URL {
        switch self {
        case .userLocalBin:
            return
                homeDirectory
                .appendingPathComponent(".local/bin", isDirectory: true)
                .appendingPathComponent(cliName, isDirectory: false)
                .standardizedFileURL
        case .usrLocalBin:
            return
                usrLocalBinDirectory
                .appendingPathComponent(cliName, isDirectory: false)
                .standardizedFileURL
        }
    }
}

/// Current installation state of a CLI symlink destination.
public enum CLIInstallStatus: Sendable, Equatable {
    /// No file or symlink exists at `destination`.
    case notInstalled(destination: URL)
    /// A symlink exists at `destination` and resolves to the current app bundle's embedded CLI binary.
    case installedMatching(destination: URL, target: URL)
    /// A symlink exists at `destination`, but points to `currentTarget` rather than `expectedTarget`.
    case installedPointingElsewhere(destination: URL, currentTarget: URL, expectedTarget: URL)
    /// A regular file or directory exists at `destination`; installer refuses to overwrite non-symlinks.
    case conflictRegularFile(destination: URL)
}

/// Typed errors thrown by `CLIInstaller` (`PLAN.md` §10, §11 T16).
public enum CLIInstallerError: Error, Sendable, Equatable, LocalizedError {
    case consentRequired
    case embeddedBinaryNotFound(URL)
    case destinationIsRegularFile(URL)
    case destinationIsDirectory(URL)
    case permissionDenied(path: String, details: String)
    case ioFailure(path: String, details: String)

    public var errorDescription: String? {
        switch self {
        case .consentRequired:
            return "Installing or removing the \(Product.cliName) symlink requires explicit user consent."
        case .embeddedBinaryNotFound(let url):
            return
                "Embedded \(Product.cliName) helper binary was not found at '\(url.path)'. Run from a packaged \(Product.name).app bundle."
        case .destinationIsRegularFile(let url):
            return
                "Refusing to overwrite existing non-symlink file at '\(url.path)'. Move or remove it manually first."
        case .destinationIsDirectory(let url):
            return "Destination '\(url.path)' is an existing directory."
        case .permissionDenied(let path, let details):
            return
                "Permission denied while writing '\(path)' (\(details)). Choose ~/.local/bin/\(Product.cliName) or grant write permission."
        case .ioFailure(let path, let details):
            return "Failed to update symlink at '\(path)': \(details)"
        }
    }
}

/// Outcome of a consented CLI symlink installation.
public struct CLIInstallResult: Sendable, Equatable {
    public var symlinkURL: URL
    public var targetBinaryURL: URL
    public var replacedExistingSymlink: Bool
    public var isDirectoryOnPATH: Bool

    public init(
        symlinkURL: URL,
        targetBinaryURL: URL,
        replacedExistingSymlink: Bool,
        isDirectoryOnPATH: Bool
    ) {
        self.symlinkURL = symlinkURL
        self.targetBinaryURL = targetBinaryURL
        self.replacedExistingSymlink = replacedExistingSymlink
        self.isDirectoryOnPATH = isDirectoryOnPATH
    }
}

/// Protocol abstracting consented companion CLI symlink installation (`PLAN.md` §0 Rule 3, §11 T16).
public protocol CLIInstalling: Sendable {
    /// Returns the URL of `<App.app>/Contents/Helpers/<Product.cliName>` if present and executable.
    func embeddedCLIBinaryURL() -> URL?

    /// Inspects `destinationSymlinkURL` without modifying disk state.
    func status(at destinationSymlinkURL: URL) -> CLIInstallStatus

    /// Creates or updates the symlink at `destinationSymlinkURL` pointing to the embedded CLI helper.
    /// Throws `CLIInstallerError.consentRequired` if `userConsented` is `false`.
    func install(
        to destinationSymlinkURL: URL,
        userConsented: Bool,
        pathEnvironment: String?
    ) throws -> CLIInstallResult

    /// Removes an installed CLI symlink at `destinationSymlinkURL` after explicit consent.
    /// Never deletes regular files or directories.
    func uninstall(at destinationSymlinkURL: URL, userConsented: Bool) throws
}

/// Consented symlink installer for `<App.app>/Contents/Helpers/<Product.cliName>` (`PLAN.md` §11 T16).
///
/// Lives in `BentoFixes` so all filesystem symlink/directory writes remain strictly confined to `BentoFixes`.
public struct CLIInstaller: CLIInstalling, Sendable {
    private let appBundleURL: URL
    private let explicitBinaryURL: URL?
    private let cliName: String

    /// Creates an installer resolving `Contents/Helpers/<Product.cliName>` inside `appBundleURL`
    /// (or `explicitBinaryURL` when overridden in tests).
    public init(
        appBundleURL: URL = Bundle.main.bundleURL,
        explicitBinaryURL: URL? = nil,
        cliName: String = Product.cliName
    ) {
        self.appBundleURL = appBundleURL.standardizedFileURL
        self.explicitBinaryURL = explicitBinaryURL?.standardizedFileURL
        self.cliName = cliName
    }

    /// Computes the canonical helper path `<App.app>/Contents/Helpers/<cliName>`.
    public static func embeddedBinaryURL(
        inAppBundle appBundleURL: URL,
        cliName: String = Product.cliName
    ) -> URL {
        appBundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(cliName, isDirectory: false)
            .standardizedFileURL
    }

    private var candidateHelperURL: URL {
        explicitBinaryURL ?? Self.embeddedBinaryURL(inAppBundle: appBundleURL, cliName: cliName)
    }

    public func embeddedCLIBinaryURL() -> URL? {
        let candidate = candidateHelperURL
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            return nil
        }
        return candidate
    }

    public func status(at destinationSymlinkURL: URL) -> CLIInstallStatus {
        let destination = destinationSymlinkURL.standardizedFileURL
        let expectedTarget = candidateHelperURL

        var info = stat()
        guard lstat(destination.path, &info) == 0 else {
            return .notInstalled(destination: destination)
        }

        let fileType = info.st_mode & S_IFMT
        guard fileType == S_IFLNK else {
            return .conflictRegularFile(destination: destination)
        }

        guard let rawTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path) else {
            return .installedPointingElsewhere(
                destination: destination,
                currentTarget: destination,
                expectedTarget: expectedTarget
            )
        }

        let resolvedTarget: URL
        if rawTarget.hasPrefix("/") {
            resolvedTarget = URL(fileURLWithPath: rawTarget).standardizedFileURL
        } else {
            resolvedTarget =
                destination
                .deletingLastPathComponent()
                .appendingPathComponent(rawTarget)
                .standardizedFileURL
        }

        if resolvedTarget == expectedTarget {
            return .installedMatching(destination: destination, target: expectedTarget)
        }
        return .installedPointingElsewhere(
            destination: destination,
            currentTarget: resolvedTarget,
            expectedTarget: expectedTarget
        )
    }

    public func install(
        to destinationSymlinkURL: URL,
        userConsented: Bool,
        pathEnvironment: String?
    ) throws -> CLIInstallResult {
        guard userConsented else {
            throw CLIInstallerError.consentRequired
        }

        let target = candidateHelperURL
        guard FileManager.default.isExecutableFile(atPath: target.path) else {
            throw CLIInstallerError.embeddedBinaryNotFound(target)
        }

        let destination = destinationSymlinkURL.standardizedFileURL
        let parentDir = destination.deletingLastPathComponent().standardizedFileURL

        var replacedSymlink = false
        var info = stat()
        if lstat(destination.path, &info) == 0 {
            let fileType = info.st_mode & S_IFMT
            if fileType == S_IFLNK {
                do {
                    try FileManager.default.removeItem(atPath: destination.path)
                    replacedSymlink = true
                } catch {
                    throw Self.classifyFileManagerError(error, path: destination.path)
                }
            } else if fileType == S_IFDIR {
                throw CLIInstallerError.destinationIsDirectory(destination)
            } else {
                throw CLIInstallerError.destinationIsRegularFile(destination)
            }
        } else {
            do {
                try FileManager.default.createDirectory(
                    at: parentDir,
                    withIntermediateDirectories: true
                )
            } catch {
                throw Self.classifyFileManagerError(error, path: parentDir.path)
            }
        }

        do {
            try FileManager.default.createSymbolicLink(
                atPath: destination.path,
                withDestinationPath: target.path
            )
        } catch {
            throw Self.classifyFileManagerError(error, path: destination.path)
        }

        let isOnPATH = Self.directoryIsListedOnPATH(parentDir, pathEnvironment: pathEnvironment)
        return CLIInstallResult(
            symlinkURL: destination,
            targetBinaryURL: target,
            replacedExistingSymlink: replacedSymlink,
            isDirectoryOnPATH: isOnPATH
        )
    }

    public func uninstall(at destinationSymlinkURL: URL, userConsented: Bool) throws {
        guard userConsented else {
            throw CLIInstallerError.consentRequired
        }

        let destination = destinationSymlinkURL.standardizedFileURL
        var info = stat()
        guard lstat(destination.path, &info) == 0 else {
            if errno == ENOENT {
                return
            }
            throw CLIInstallerError.ioFailure(
                path: destination.path,
                details: String(cString: strerror(errno))
            )
        }

        let fileType = info.st_mode & S_IFMT
        if fileType == S_IFDIR {
            throw CLIInstallerError.destinationIsDirectory(destination)
        }
        guard fileType == S_IFLNK else {
            throw CLIInstallerError.destinationIsRegularFile(destination)
        }

        do {
            try FileManager.default.removeItem(atPath: destination.path)
        } catch {
            throw Self.classifyFileManagerError(error, path: destination.path)
        }
    }

    private static func directoryIsListedOnPATH(_ directory: URL, pathEnvironment: String?) -> Bool {
        guard let pathEnvironment, !pathEnvironment.isEmpty else {
            return false
        }
        let targetPath = directory.standardizedFileURL.path
        for component in pathEnvironment.split(separator: ":") {
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = URL(fileURLWithPath: trimmed).standardizedFileURL.path
            if normalized == targetPath {
                return true
            }
        }
        return false
    }

    private static func classifyFileManagerError(_ error: Error, path: String) -> CLIInstallerError {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain
            && (nsError.code == NSFileWriteNoPermissionError || nsError.code == NSFileReadNoPermissionError)
        {
            return .permissionDenied(path: path, details: nsError.localizedDescription)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.domain == NSPOSIXErrorDomain,
            underlying.code == Int(EACCES) || underlying.code == Int(EPERM)
        {
            return .permissionDenied(path: path, details: underlying.localizedDescription)
        }
        return .ioFailure(path: path, details: nsError.localizedDescription)
    }
}
