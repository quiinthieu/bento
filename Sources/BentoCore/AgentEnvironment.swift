import Foundation

/// Execution context injected into adapters and scanners so tests use isolated fixture homes
/// and deterministic clocks without ever touching the real `$HOME`.
public struct AgentEnvironment: Sendable {
    /// Effective home directory URL (fixture home in tests).
    public var home: URL
    /// Environment variables consulted for config path overrides (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, etc.).
    public var env: [String: String]
    /// Read-only filesystem accessor.
    public var fileSystem: any ReadOnlyFileSystem
    /// Clock closure returning the current timestamp.
    public var now: @Sendable () -> Date

    /// Creates an `AgentEnvironment` with explicit dependencies.
    public init(
        home: URL,
        env: [String: String] = [:],
        fileSystem: any ReadOnlyFileSystem = LocalReadOnlyFileSystem(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.home = home
        self.env = env
        self.fileSystem = fileSystem
        self.now = now
    }
}
