import BentoCore
import CryptoKit
import Darwin
import Foundation

/// Deterministic filesystem state inspection and SHA-256 tree hashing without traversing into symlinks.
enum DirectoryHasher {
    /// Checks whether a filesystem entry (including a broken symlink) exists at `path` via `lstat`.
    static func lstatExists(atPath path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// Recursively lists sorted relative entry paths inside `root` without descending into symlinked directories.
    static func listRelativeEntries(under root: URL, ignoreDSStore: Bool = false) throws -> [String] {
        let fm = FileManager.default
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        var results: [String] = []

        func walk(currentFullPath: String, currentRelativePrefix: String) throws {
            let names = try fm.contentsOfDirectory(atPath: currentFullPath).sorted()
            for name in names {
                if ignoreDSStore && name == ".DS_Store" {
                    continue
                }
                let childRel = currentRelativePrefix.isEmpty ? name : "\(currentRelativePrefix)/\(name)"
                let childFull = (currentFullPath as NSString).appendingPathComponent(name)
                let attrs = try fm.attributesOfItem(atPath: childFull)
                let fileType = attrs[.type] as? FileAttributeType
                results.append(childRel)
                if fileType == .typeDirectory {
                    try walk(currentFullPath: childFull, currentRelativePrefix: childRel)
                }
            }
        }

        try walk(currentFullPath: rootPath, currentRelativePrefix: "")
        return results.sorted()
    }

    /// Inspects the current filesystem state at `path` for `PathPrecondition` verification.
    static func currentState(atPath path: String) throws -> PathPrecondition.ExpectedState {
        guard lstatExists(atPath: path) else {
            return .absent
        }
        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: path)
        let fileType = attrs[.type] as? FileAttributeType
        if fileType == .typeSymbolicLink {
            let dest = try fm.destinationOfSymbolicLink(atPath: path)
            return .symlink(destination: dest)
        }
        if fileType == .typeDirectory {
            let hash = try treeHash(at: URL(fileURLWithPath: path, isDirectory: true))
            return .directory(treeSHA256: hash)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return .regularFile(sha256: ContentHasher.sha256Hex(data))
    }

    /// Computes a deterministic SHA-256 hash of a directory tree (paths, types, symlink destinations, and file bytes).
    static func treeHash(at root: URL, ignoreDSStore: Bool = false) throws -> String {
        let fm = FileManager.default
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let relPaths = try listRelativeEntries(under: root, ignoreDSStore: ignoreDSStore)

        var hasher = SHA256()
        for rel in relPaths {
            let fullPath = (rootPath as NSString).appendingPathComponent(rel)
            let attrs = try fm.attributesOfItem(atPath: fullPath)
            let fileType = attrs[.type] as? FileAttributeType
            hasher.update(data: Data("rel:/\(rel)|".utf8))
            if fileType == .typeSymbolicLink {
                let dest = try fm.destinationOfSymbolicLink(atPath: fullPath)
                hasher.update(data: Data("symlink:\(dest)\n".utf8))
            } else if fileType == .typeDirectory {
                hasher.update(data: Data("dir\n".utf8))
            } else {
                let bytes = try Data(contentsOf: URL(fileURLWithPath: fullPath))
                hasher.update(data: Data("file:\(bytes.count):".utf8))
                hasher.update(data: bytes)
                hasher.update(data: Data("\n".utf8))
            }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Lists sorted relative non-directory file paths inside `dir` (ignoring `.DS_Store` and not traversing into symlinks).
    static func listRelativeFilePaths(under dir: URL) throws -> [String] {
        let fm = FileManager.default
        let rootPath = dir.resolvingSymlinksInPath().standardizedFileURL.path
        let entries = try listRelativeEntries(under: dir, ignoreDSStore: true)
        var files: [String] = []
        for rel in entries {
            let fullPath = (rootPath as NSString).appendingPathComponent(rel)
            let attrs = try fm.attributesOfItem(atPath: fullPath)
            let fileType = attrs[.type] as? FileAttributeType
            if fileType != .typeDirectory {
                files.append(rel)
            }
        }
        return files.sorted()
    }
}
