import BentoCore
import Foundation

/// Errors thrown when loading a named fixture home scenario.
public enum FixtureHomeError: Error, Sendable, Equatable {
    case scenarioNotFound(name: String, expectedPath: String)
}

/// Test helper locating isolated fake `$HOME` trees under `Fixtures/homes/<scenario>`
/// so tests never read or mutate the developer's real `$HOME`.
public struct FixtureHome: Sendable {
    /// Fixed default timestamp (`2023-11-14T22:13:20Z`) for deterministic tests.
    public static let defaultTimestamp = Date(timeIntervalSince1970: 1_700_000_000)

    /// Scenario folder name (e.g. `"empty"`, `"polyglot"`).
    public let scenario: String
    /// Absolute directory URL of `Fixtures/homes/<scenario>`.
    public let url: URL

    /// Resolves `Fixtures/homes/<scenario>` relative to the repository root.
    public init(scenario: String) throws {
        let repoRoot = Self.repositoryRoot()
        let candidate =
            repoRoot
            .appendingPathComponent("Fixtures/homes", isDirectory: true)
            .appendingPathComponent(scenario, isDirectory: true)
            .standardizedFileURL

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue else {
            throw FixtureHomeError.scenarioNotFound(name: scenario, expectedPath: candidate.path)
        }

        self.scenario = scenario
        self.url = candidate
    }

    /// Builds an isolated `AgentEnvironment` rooted at this fixture home.
    /// Injects `BENTO_SYSTEM_ROOT` pointing at the fixture home unless explicitly overridden,
    /// ensuring system-managed paths (`/Library/...`, `/etc/...`) never leak from the host OS.
    public func makeEnvironment(
        env: [String: String] = [:],
        fileSystem: any ReadOnlyFileSystem = LocalReadOnlyFileSystem(),
        now: Date = Self.defaultTimestamp
    ) -> AgentEnvironment {
        var mergedEnv = ["BENTO_SYSTEM_ROOT": url.path]
        for (key, value) in env {
            mergedEnv[key] = value
        }
        return AgentEnvironment(
            home: url,
            env: mergedEnv,
            fileSystem: fileSystem,
            now: { now }
        )
    }

    /// Copies the fixture home into a fresh temporary directory for read-only (`chmod -R a-w`)
    /// or reversible-fix round-trip tests. Caller is responsible for removing the returned directory.
    public func copyToTemporaryDirectory() throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-fixture-\(scenario)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// Repository root URL resolved from this source file's location.
    public static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
