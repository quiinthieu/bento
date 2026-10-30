import BentoCore
import Foundation
import os

/// Thread-safe `ReadOnlyFileSystem` wrapper recording all accessed paths so contract tests
/// can prove adapters never escape their injected fixture home or bypass `ReadOnlyFileSystem`.
public final class RecordingReadOnlyFileSystem: ReadOnlyFileSystem, Sendable {
    private let underlying: any ReadOnlyFileSystem
    private let accessedPathsLock = OSAllocatedUnfairLock(initialState: [String]())

    /// Creates a recording wrapper around `underlying`.
    public init(wrapping underlying: any ReadOnlyFileSystem = LocalReadOnlyFileSystem()) {
        self.underlying = underlying
    }

    /// Snapshot of all filesystem paths accessed in call order.
    public var accessedPaths: [String] {
        accessedPathsLock.withLock { $0 }
    }

    public func contents(at url: URL) throws -> Data {
        record(url)
        return try underlying.contents(at: url)
    }

    public func list(_ url: URL) throws -> [URL] {
        record(url)
        return try underlying.list(url)
    }

    public func attributes(_ url: URL) throws -> FileAttributes {
        record(url)
        return try underlying.attributes(url)
    }

    public func exists(_ url: URL) -> Bool {
        record(url)
        return underlying.exists(url)
    }

    public func resolveSymlinks(_ url: URL) -> URL {
        record(url)
        return underlying.resolveSymlinks(url)
    }

    private func record(_ url: URL) {
        let path = url.standardizedFileURL.path
        accessedPathsLock.withLock { $0.append(path) }
    }
}
