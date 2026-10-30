import CryptoKit
import Foundation

/// Deterministic SHA-256 content hashing helpers for cache keys and TOCTOU verification.
public enum ContentHasher: Sendable {
    /// Returns the lowercase 64-character hexadecimal SHA-256 digest of raw bytes.
    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Normalizes CRLF line endings to LF and returns the lowercase hexadecimal SHA-256 digest.
    public static func sha256NormalizedText(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        return sha256Hex(Data(normalized.utf8))
    }
}
