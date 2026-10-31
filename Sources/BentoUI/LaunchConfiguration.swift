import BentoCore
import Foundation

/// Errors thrown while parsing macOS application launch arguments.
public enum LaunchConfigurationError: Error, LocalizedError, Sendable, Equatable {
    case missingValue(flag: String)
    case fixtureHomeNotFound(scenario: String)

    public var errorDescription: String? {
        switch self {
        case .missingValue(let flag):
            return "Launch argument '\(flag)' requires a value."
        case .fixtureHomeNotFound(let scenario):
            return "Could not locate fixture home scenario '\(scenario)' under Fixtures/homes."
        }
    }
}

/// Parsed command-line and environment launch options for the macOS SwiftUI application (`PLAN.md` §6.7, §11 T15).
public struct LaunchConfiguration: Sendable, Equatable {
    public var homeURL: URL
    public var isFixtureMode: Bool
    public var supportDirectoryOverride: URL?
    public var skipOnboarding: Bool
    public var forceShowOnboarding: Bool
    public var smokeTestQuit: Bool
    public var environmentOverrides: [String: String]

    public init(
        homeURL: URL,
        isFixtureMode: Bool = false,
        supportDirectoryOverride: URL? = nil,
        skipOnboarding: Bool = false,
        forceShowOnboarding: Bool = false,
        smokeTestQuit: Bool = false,
        environmentOverrides: [String: String] = [:]
    ) {
        self.homeURL = homeURL.standardizedFileURL
        self.isFixtureMode = isFixtureMode
        self.supportDirectoryOverride = supportDirectoryOverride?.standardizedFileURL
        self.skipOnboarding = skipOnboarding
        self.forceShowOnboarding = forceShowOnboarding
        self.smokeTestQuit = smokeTestQuit
        self.environmentOverrides = environmentOverrides
    }

    /// Parses process arguments (such as `-fixtureHome polyglot`, `-supportDir <path>`,
    /// `-skipOnboarding`, `-showOnboarding`, and `--smoke-test-quit`).
    public static func parse(
        arguments: [String] = CommandLine.arguments,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> LaunchConfiguration {
        var resolvedHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        var isFixture = false
        var supportOverride: URL?
        var skipOnboarding = false
        var forceShowOnboarding = false
        var smokeTestQuit = false
        var envOverrides: [String: String] = [:]

        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "-fixtureHome", "--fixture-home":
                guard index + 1 < arguments.count else {
                    throw LaunchConfigurationError.missingValue(flag: arg)
                }
                let rawValue = arguments[index + 1]
                resolvedHome = try resolveFixtureHome(rawValue, processEnvironment: processEnvironment)
                isFixture = true
                envOverrides["BENTO_SYSTEM_ROOT"] = resolvedHome.path
                index += 2

            case "-supportDir", "--support-dir":
                guard index + 1 < arguments.count else {
                    throw LaunchConfigurationError.missingValue(flag: arg)
                }
                let rawPath = (arguments[index + 1] as NSString).expandingTildeInPath
                supportOverride = URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
                index += 2

            case "-skipOnboarding", "--skip-onboarding":
                skipOnboarding = true
                index += 1

            case "-showOnboarding", "--show-onboarding":
                forceShowOnboarding = true
                index += 1

            case "--smoke-test-quit":
                smokeTestQuit = true
                index += 1

            default:
                index += 1
            }
        }

        return LaunchConfiguration(
            homeURL: resolvedHome,
            isFixtureMode: isFixture,
            supportDirectoryOverride: supportOverride,
            skipOnboarding: skipOnboarding,
            forceShowOnboarding: forceShowOnboarding,
            smokeTestQuit: smokeTestQuit,
            environmentOverrides: envOverrides
        )
    }

    private static func resolveFixtureHome(
        _ rawValue: String,
        processEnvironment: [String: String]
    ) throws -> URL {
        let fm = FileManager.default
        let expanded = (rawValue as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") || rawValue.hasPrefix(".") {
            var isDir: ObjCBool = false
            let directURL = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
            if fm.fileExists(atPath: directURL.path, isDirectory: &isDir), isDir.boolValue {
                return directURL
            }
        }

        var searchSeeds: [URL] = []
        if let repoRoot = processEnvironment["BENTO_REPO_ROOT"], !repoRoot.isEmpty {
            searchSeeds.append(URL(fileURLWithPath: repoRoot, isDirectory: true))
        }
        searchSeeds.append(URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true))
        searchSeeds.append(Bundle.main.bundleURL)
        searchSeeds.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent())

        for seed in searchSeeds {
            if let hit = findFixtureScenario(named: rawValue, ascendingFrom: seed, fileManager: fm) {
                return hit
            }
        }

        throw LaunchConfigurationError.fixtureHomeNotFound(scenario: rawValue)
    }

    private static func findFixtureScenario(
        named scenario: String,
        ascendingFrom start: URL,
        fileManager: FileManager
    ) -> URL? {
        var current = start.standardizedFileURL
        for _ in 0..<12 {
            let candidate =
                current
                .appendingPathComponent("Fixtures", isDirectory: true)
                .appendingPathComponent("homes", isDirectory: true)
                .appendingPathComponent(scenario, isDirectory: true)
                .standardizedFileURL
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }
        return nil
    }
}
