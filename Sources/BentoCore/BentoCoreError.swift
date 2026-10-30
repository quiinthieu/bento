import Foundation

/// Typed errors produced by `BentoCore` operations.
public enum BentoCoreError: Error, Sendable, Equatable {
    /// A requested file or directory does not exist at the given path.
    case fileNotFound(path: String)
    /// File system metadata could not be read for the given path.
    case unreadableAttributes(path: String)
    /// A file read failed with an underlying description.
    case readFailed(path: String, reason: String)
}
