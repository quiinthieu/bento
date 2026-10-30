import Darwin
import Foundation

/// Production `ReadOnlyFileSystem` backed by read-only `Foundation` and POSIX `lstat` calls.
public struct LocalReadOnlyFileSystem: ReadOnlyFileSystem, Sendable {
    /// Creates a read-only local filesystem reader.
    public init() {}

    public func contents(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
        {
            throw BentoCoreError.fileNotFound(path: url.path)
        } catch {
            throw BentoCoreError.readFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    public func list(_ url: URL) throws -> [URL] {
        do {
            let entries = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            )
            return entries.sorted { lhs, rhs in
                lhs.lastPathComponent.utf8.lexicographicallyPrecedes(rhs.lastPathComponent.utf8)
            }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
        {
            throw BentoCoreError.fileNotFound(path: url.path)
        } catch {
            throw BentoCoreError.readFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    public func attributes(_ url: URL) throws -> FileAttributes {
        var statBuf = stat()
        guard lstat(url.path, &statBuf) == 0 else {
            if errno == ENOENT {
                throw BentoCoreError.fileNotFound(path: url.path)
            }
            throw BentoCoreError.unreadableAttributes(path: url.path)
        }

        let fileType = statBuf.st_mode & S_IFMT
        let seconds = TimeInterval(statBuf.st_mtimespec.tv_sec)
        let nanos = TimeInterval(statBuf.st_mtimespec.tv_nsec) / 1_000_000_000

        return FileAttributes(
            size: UInt64(max(0, statBuf.st_size)),
            modificationDate: Date(timeIntervalSince1970: seconds + nanos),
            inode: statBuf.st_ino,
            isDirectory: fileType == S_IFDIR,
            isSymlink: fileType == S_IFLNK
        )
    }

    public func exists(_ url: URL) -> Bool {
        var statBuf = stat()
        return lstat(url.path, &statBuf) == 0
    }

    public func resolveSymlinks(_ url: URL) -> URL {
        url.resolvingSymlinksInPath()
    }
}
