import Foundation

/// Read-only filesystem metadata for a file, directory, or symbolic link.
public struct FileAttributes: Sendable, Codable, Hashable {
    /// Byte length reported by `lstat`.
    public var size: UInt64
    /// Last modification timestamp.
    public var modificationDate: Date
    /// Filesystem inode identifier (`st_ino`), used for log rotation detection.
    public var inode: UInt64
    /// `true` when the entry itself is a directory (not a symlink to a directory).
    public var isDirectory: Bool
    /// `true` when the entry itself is a symbolic link.
    public var isSymlink: Bool

    /// Creates a file attributes record.
    public init(
        size: UInt64,
        modificationDate: Date,
        inode: UInt64,
        isDirectory: Bool,
        isSymlink: Bool
    ) {
        self.size = size
        self.modificationDate = modificationDate
        self.inode = inode
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
    }
}
