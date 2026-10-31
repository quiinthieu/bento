import BentoCore
import Foundation

/// Thread-safe store tracking explicit user consent per MCP `serverConfigHash` (`PLAN.md` §6.4, §7).
///
/// Because consent is keyed by `MCPServerConfigHasher.hash(config)`, any change to `command`, `args`,
/// `url`, or `envKeys` produces a new digest and automatically requires fresh user approval.
public final class MCPConsentStore: @unchecked Sendable {
    private let lock = NSLock()
    private let persistence: (any MCPConsentPersisting)?
    private var approvedHashes: Set<String>

    /// Creates a consent store optionally backed by `persistence` (`BentoStore`).
    public init(
        persistence: (any MCPConsentPersisting)? = nil,
        initialHashes: Set<String> = []
    ) throws {
        self.persistence = persistence
        var loaded = initialHashes
        if let persistence {
            loaded.formUnion(try persistence.consentedMCPConfigHashes())
        }
        self.approvedHashes = loaded
    }

    /// Snapshot of all currently approved `serverConfigHash` values.
    public var allConsentedHashes: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return approvedHashes
    }

    /// Returns `true` when explicit consent has been granted for `config`'s exact `serverConfigHash`.
    public func hasConsent(for config: MCPServerConfig) -> Bool {
        hasConsent(forHash: MCPServerConfigHasher.hash(config))
    }

    /// Returns `true` when explicit consent has been granted for `serverConfigHash`.
    public func hasConsent(forHash serverConfigHash: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return approvedHashes.contains(serverConfigHash)
    }

    /// Records explicit user consent for `config` and persists if backed by `MCPConsentPersisting`.
    public func grantConsent(for config: MCPServerConfig) throws {
        try grantConsent(forHash: MCPServerConfigHasher.hash(config))
    }

    /// Records explicit user consent for `serverConfigHash` and persists if backed by `MCPConsentPersisting`.
    public func grantConsent(forHash serverConfigHash: String) throws {
        let updated: Set<String> = {
            lock.lock()
            defer { lock.unlock() }
            approvedHashes.insert(serverConfigHash)
            return approvedHashes
        }()
        try persistence?.saveConsentedMCPConfigHashes(updated)
    }

    /// Revokes prior consent for `config`.
    public func revokeConsent(for config: MCPServerConfig) throws {
        try revokeConsent(forHash: MCPServerConfigHasher.hash(config))
    }

    /// Revokes prior consent for `serverConfigHash`.
    public func revokeConsent(forHash serverConfigHash: String) throws {
        let updated: Set<String> = {
            lock.lock()
            defer { lock.unlock() }
            approvedHashes.remove(serverConfigHash)
            return approvedHashes
        }()
        try persistence?.saveConsentedMCPConfigHashes(updated)
    }

    /// Clears all stored MCP probe consents.
    public func revokeAll() throws {
        lock.lock()
        approvedHashes.removeAll()
        lock.unlock()
        try persistence?.saveConsentedMCPConfigHashes([])
    }
}
