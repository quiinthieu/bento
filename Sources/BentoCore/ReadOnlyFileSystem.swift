import Foundation

/// Narrow read-only filesystem abstraction injected into adapters, parsers, and scanners
/// so no discovery or audit code can mutate user files.
public protocol ReadOnlyFileSystem: Sendable {
    /// Reads the raw bytes of the file at `url`.
    func contents(at url: URL) throws -> Data

    /// Lists direct child URLs inside the directory at `url` (including dotfiles) in deterministic order.
    func list(_ url: URL) throws -> [URL]

    /// Reads `lstat` metadata for `url` without following the final symbolic link.
    func attributes(_ url: URL) throws -> FileAttributes

    /// Returns `true` if a filesystem entry (including a symlink) exists at `url`.
    func exists(_ url: URL) -> Bool

    /// Resolves symbolic links along `url`.
    func resolveSymlinks(_ url: URL) -> URL
}
