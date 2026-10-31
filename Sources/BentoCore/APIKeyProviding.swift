import Foundation
import Security
import Synchronization

/// Supported opt-in exact token-counting API providers (`PLAN.md` §6.3, §6.8, §7).
public enum TokenCountAPIProviderID: String, Sendable, Codable, CaseIterable {
    case anthropic
    case gemini
}

/// Errors encountered when reading or writing API keys in Keychain.
public enum APIKeyStoreError: Error, Sendable, Equatable {
    case keychainFailure(status: Int32)
    case invalidUTF8Payload
}

/// Abstraction for retrieving and storing user-provided token-count API keys without persisting
/// secrets on disk or in SQLite (`PLAN.md` §6.3, §7).
public protocol APIKeyProviding: Sendable {
    func apiKey(for provider: TokenCountAPIProviderID) throws -> String?
    func setAPIKey(_ key: String?, for provider: TokenCountAPIProviderID) throws
}

/// macOS Keychain-backed `APIKeyProviding` scoped to `Product.bundleID` (`PLAN.md` §7).
public struct KeychainAPIKeyStore: APIKeyProviding, Sendable {
    public let service: String

    public init(service: String = "\(Product.bundleID).api-keys") {
        self.service = service
    }

    public func keychainReference(for provider: TokenCountAPIProviderID) -> String {
        "keychain://\(service)/\(provider.rawValue)"
    }

    public func apiKey(for provider: TokenCountAPIProviderID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw APIKeyStoreError.keychainFailure(status: status)
        }
        guard let data = item as? Data, let decoded = String(data: data, encoding: .utf8) else {
            throw APIKeyStoreError.invalidUTF8Payload
        }
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func setAPIKey(_ key: String?, for provider: TokenCountAPIProviderID) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue
        ]

        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            let deleteStatus = SecItemDelete(baseQuery as CFDictionary)
            if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
                throw APIKeyStoreError.keychainFailure(status: deleteStatus)
            }
            return
        }

        let payload = Data(trimmed.utf8)
        let updateAttrs: [String: Any] = [
            kSecValueData as String: payload
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = payload
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw APIKeyStoreError.keychainFailure(status: addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw APIKeyStoreError.keychainFailure(status: updateStatus)
        }
    }
}

/// Hermetic in-memory `APIKeyProviding` implementation for unit tests and ephemeral CLI overrides.
public final class InMemoryAPIKeyStore: APIKeyProviding, Sendable {
    private let storage: Mutex<[TokenCountAPIProviderID: String]>

    public init(initialKeys: [TokenCountAPIProviderID: String] = [:]) {
        var sanitized: [TokenCountAPIProviderID: String] = [:]
        for (provider, raw) in initialKeys {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                sanitized[provider] = trimmed
            }
        }
        self.storage = Mutex(sanitized)
    }

    public func apiKey(for provider: TokenCountAPIProviderID) throws -> String? {
        storage.withLock { $0[provider] }
    }

    public func setAPIKey(_ key: String?, for provider: TokenCountAPIProviderID) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        storage.withLock { dict in
            if let trimmed, !trimmed.isEmpty {
                dict[provider] = trimmed
            } else {
                dict.removeValue(forKey: provider)
            }
        }
    }
}
