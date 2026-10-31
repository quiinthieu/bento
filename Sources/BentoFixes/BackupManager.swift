import BentoCore
import Foundation

/// Serializable backup manifest written to `<supportDirectory>/Backups/<timestamp>-<fixID>/manifest.json` (`PLAN.md` §6.6).
public struct BackupManifest: Sendable, Codable, Hashable {
    public enum ItemKind: String, Sendable, Codable, Hashable {
        case regularFile
        case directory
        case symlink
    }

    public struct ItemRecord: Sendable, Codable, Hashable {
        public var originalPath: String
        public var existedBefore: Bool
        public var kind: ItemKind?
        public var backupSubpath: String?
        public var preApplyHash: String?
        public var posixPermissions: Int?
        public var symlinkDestination: String?
        public var directoryModes: [String: Int]?
        public var postApplyState: PathPrecondition.ExpectedState?
    }

    public var fixID: String
    public var createdAt: Date
    public var items: [ItemRecord]
    public var createdDirectories: [String]
    public var trashedPaths: [String]
}

/// Manages pre-apply backups, post-apply state snapshots, TOCTOU-safe undo checks, and byte-identical restoration.
enum BackupManager {
    private static let manifestFilename = "manifest.json"

    static func makeBackupDirectoryURL(
        supportDirectory: URL,
        fixID: String,
        now: Date
    ) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        let sanitizedID = fixID.replacingOccurrences(of: "/", with: "_")
        let base = supportDirectory
            .standardizedFileURL
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent("\(stamp)-\(sanitizedID)", isDirectory: true)
        if !DirectoryHasher.lstatExists(atPath: base.path) {
            return base
        }
        return supportDirectory
            .standardizedFileURL
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent("\(stamp)-\(sanitizedID)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    /// Captures a complete backup of every path that `plan` will mutate, plus ancestor directories that do not yet exist.
    static func createBackup(
        for plan: FixPlan,
        at backupDir: URL,
        now: Date
    ) throws -> BackupManifest {
        let fm = FileManager.default
        let itemsDir = backupDir.appendingPathComponent("items", isDirectory: true)
        try fm.createDirectory(at: itemsDir, withIntermediateDirectories: true)

        var seenPaths: Set<String> = []
        var orderedPaths: [String] = []
        for op in plan.operations {
            for rawPath in op.mutatedPaths {
                let normalized = normalizeLexicalPath(rawPath)
                if seenPaths.insert(normalized).inserted {
                    orderedPaths.append(normalized)
                }
            }
        }

        // Record every ancestor directory that does not exist yet so rollback/undo removes newly created empty dirs.
        var missingDirs: Set<String> = []
        for op in plan.operations {
            switch op {
            case .mkdir(let dirPath):
                collectNonExistentAncestors(
                    startingAt: normalizeLexicalPath(dirPath),
                    into: &missingDirs
                )
            case .writeFile(let path, _, _),
                .symlink(let path, _),
                .moveToTrash(let path, _):
                let parent = URL(fileURLWithPath: normalizeLexicalPath(path)).deletingLastPathComponent().path
                collectNonExistentAncestors(startingAt: parent, into: &missingDirs)
            case .moveItem(let fromPath, let toPath, _):
                let fromParent = URL(fileURLWithPath: normalizeLexicalPath(fromPath)).deletingLastPathComponent().path
                let toParent = URL(fileURLWithPath: normalizeLexicalPath(toPath)).deletingLastPathComponent().path
                collectNonExistentAncestors(startingAt: fromParent, into: &missingDirs)
                collectNonExistentAncestors(startingAt: toParent, into: &missingDirs)
            }
        }

        let sortedCreatedDirs = missingDirs.sorted { lhs, rhs in
            let lhsDepth = lhs.split(separator: "/").count
            let rhsDepth = rhs.split(separator: "/").count
            if lhsDepth != rhsDepth {
                return lhsDepth > rhsDepth
            }
            return lhs > rhs
        }

        var records: [BackupManifest.ItemRecord] = []
        for (index, path) in orderedPaths.enumerated() {
            guard DirectoryHasher.lstatExists(atPath: path) else {
                records.append(
                    BackupManifest.ItemRecord(
                        originalPath: path,
                        existedBefore: false,
                        kind: nil,
                        backupSubpath: nil,
                        preApplyHash: nil,
                        posixPermissions: nil,
                        symlinkDestination: nil,
                        directoryModes: nil,
                        postApplyState: nil
                    )
                )
                continue
            }

            let attrs = try fm.attributesOfItem(atPath: path)
            let fileType = attrs[.type] as? FileAttributeType
            let mode = ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644) & 0o777
            let subpath = "items/item-\(index)"
            let destURL = backupDir.appendingPathComponent(subpath)

            if fileType == .typeSymbolicLink {
                let symTarget = try fm.destinationOfSymbolicLink(atPath: path)
                records.append(
                    BackupManifest.ItemRecord(
                        originalPath: path,
                        existedBefore: true,
                        kind: .symlink,
                        backupSubpath: nil,
                        preApplyHash: nil,
                        posixPermissions: mode,
                        symlinkDestination: symTarget,
                        directoryModes: nil,
                        postApplyState: nil
                    )
                )
            } else if fileType == .typeDirectory {
                let sourceURL = URL(fileURLWithPath: path, isDirectory: true)
                let dirHash = try DirectoryHasher.treeHash(at: sourceURL)
                var dirModes: [String: Int] = ["": mode]
                try copyDirectoryTreePreservingSymlinks(
                    from: sourceURL,
                    to: destURL,
                    recordedModes: &dirModes
                )
                records.append(
                    BackupManifest.ItemRecord(
                        originalPath: path,
                        existedBefore: true,
                        kind: .directory,
                        backupSubpath: subpath,
                        preApplyHash: dirHash,
                        posixPermissions: mode,
                        symlinkDestination: nil,
                        directoryModes: dirModes,
                        postApplyState: nil
                    )
                )
            } else {
                let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
                try bytes.write(to: destURL, options: .atomic)
                records.append(
                    BackupManifest.ItemRecord(
                        originalPath: path,
                        existedBefore: true,
                        kind: .regularFile,
                        backupSubpath: subpath,
                        preApplyHash: ContentHasher.sha256Hex(bytes),
                        posixPermissions: mode,
                        symlinkDestination: nil,
                        directoryModes: nil,
                        postApplyState: nil
                    )
                )
            }
        }

        let manifest = BackupManifest(
            fixID: plan.id,
            createdAt: now,
            items: records,
            createdDirectories: sortedCreatedDirs,
            trashedPaths: []
        )
        try saveManifest(manifest, in: backupDir)
        return manifest
    }

    /// Updates `manifest` with post-apply hashes/states and persists `manifest.json`.
    static func finalizePostApplyState(
        _ manifest: inout BackupManifest,
        trashedPaths: [String],
        in backupDir: URL
    ) throws {
        manifest.trashedPaths = trashedPaths
        for i in manifest.items.indices {
            let path = manifest.items[i].originalPath
            manifest.items[i].postApplyState = try DirectoryHasher.currentState(atPath: path)
        }
        try saveManifest(manifest, in: backupDir)
    }

    /// Loads `manifest.json` from `backupDir`.
    static func loadManifest(from backupDir: URL) throws -> BackupManifest {
        let url = backupDir.appendingPathComponent(manifestFilename)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupManifest.self, from: data)
    }

    /// Verifies that no backed-up file or directory was modified after `apply` before running a non-forced `undo`.
    static func verifyPostApplyUnmodified(_ manifest: BackupManifest) throws {
        for item in manifest.items {
            guard let expectedPost = item.postApplyState else { continue }
            let actual = try DirectoryHasher.currentState(atPath: item.originalPath)
            if actual != expectedPost {
                throw BentoFixesError.postApplyModified(path: item.originalPath)
            }
        }
    }

    /// Restores every backed-up entry byte-for-byte (including POSIX modes, symlinks, and removing newly created dirs).
    static func restore(_ manifest: BackupManifest, from backupDir: URL) throws {
        let fm = FileManager.default

        // 1. Remove items that did not exist prior to `apply` (deepest paths first).
        let newlyCreatedItems = manifest.items
            .filter { !$0.existedBefore }
            .sorted { $0.originalPath.count > $1.originalPath.count }

        for item in newlyCreatedItems where DirectoryHasher.lstatExists(atPath: item.originalPath) {
            try fm.removeItem(atPath: item.originalPath)
        }

        // 2. Restore items that existed prior to `apply`.
        for item in manifest.items where item.existedBefore {
            let targetURL = URL(fileURLWithPath: item.originalPath)
            let parentURL = targetURL.deletingLastPathComponent()
            if !DirectoryHasher.lstatExists(atPath: parentURL.path) {
                try fm.createDirectory(at: parentURL, withIntermediateDirectories: true)
            }

            switch item.kind {
            case .regularFile:
                guard let subpath = item.backupSubpath else {
                    throw BentoFixesError.ioFailure("Missing backup subpath for '\(item.originalPath)'")
                }
                let backupFileURL = backupDir.appendingPathComponent(subpath)
                let bytes = try Data(contentsOf: backupFileURL)
                if DirectoryHasher.lstatExists(atPath: item.originalPath) {
                    let existingAttrs = try fm.attributesOfItem(atPath: item.originalPath)
                    let existingType = existingAttrs[.type] as? FileAttributeType
                    if existingType != .typeRegular {
                        try fm.removeItem(atPath: item.originalPath)
                    }
                }
                try AtomicFileWriter.writeAtomically(
                    bytes: bytes,
                    to: targetURL,
                    posixPermissions: item.posixPermissions
                )

            case .symlink:
                guard let dest = item.symlinkDestination else {
                    throw BentoFixesError.ioFailure("Missing symlink destination for '\(item.originalPath)'")
                }
                if DirectoryHasher.lstatExists(atPath: item.originalPath) {
                    try fm.removeItem(atPath: item.originalPath)
                }
                try fm.createSymbolicLink(atPath: item.originalPath, withDestinationPath: dest)

            case .directory:
                guard let subpath = item.backupSubpath else {
                    throw BentoFixesError.ioFailure("Missing backup directory for '\(item.originalPath)'")
                }
                let backupTreeURL = backupDir.appendingPathComponent(subpath, isDirectory: true)
                if DirectoryHasher.lstatExists(atPath: item.originalPath) {
                    try fm.removeItem(atPath: item.originalPath)
                }
                try restoreDirectoryTreePreservingSymlinks(
                    from: backupTreeURL,
                    to: targetURL,
                    recordedModes: item.directoryModes ?? [:],
                    rootMode: item.posixPermissions
                )

            case .none:
                break
            }
        }

        // 3. Remove orphaned trashed copies created by this fix (items have been restored from verified backup).
        for trashedPath in manifest.trashedPaths where DirectoryHasher.lstatExists(atPath: trashedPath) {
            try? fm.removeItem(atPath: trashedPath)
        }

        // 4. Remove empty ancestor directories that were newly created by this fix (deepest-first).
        for dirPath in manifest.createdDirectories where DirectoryHasher.lstatExists(atPath: dirPath) {
            if let contents = try? fm.contentsOfDirectory(atPath: dirPath), contents.isEmpty {
                try? fm.removeItem(atPath: dirPath)
            }
        }
    }

    // MARK: - Internal Helpers

    private static func saveManifest(_ manifest: BackupManifest, in backupDir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let targetURL = backupDir.appendingPathComponent(manifestFilename)
        try AtomicFileWriter.writeAtomically(bytes: data, to: targetURL, posixPermissions: 0o600)
    }

    static func normalizeLexicalPath(_ path: String) -> String {
        // Normalize `.` / `..` / trailing slashes without resolving final-component symlinks.
        (path as NSString).standardizingPath
    }

    private static func collectNonExistentAncestors(startingAt path: String, into set: inout Set<String>) {
        var current = normalizeLexicalPath(path)
        while !current.isEmpty && current != "/" {
            if DirectoryHasher.lstatExists(atPath: current) {
                break
            }
            set.insert(current)
            current = (current as NSString).deletingLastPathComponent
        }
    }

    private static func copyDirectoryTreePreservingSymlinks(
        from sourceRoot: URL,
        to destRoot: URL,
        recordedModes: inout [String: Int]
    ) throws {
        let fm = FileManager.default
        let stdSourcePath = sourceRoot.resolvingSymlinksInPath().standardizedFileURL.path
        try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)

        let relEntries = try DirectoryHasher.listRelativeEntries(under: sourceRoot)

        for rel in relEntries {
            let srcPath = (stdSourcePath as NSString).appendingPathComponent(rel)
            let dstURL = destRoot.appendingPathComponent(rel)
            let attrs = try fm.attributesOfItem(atPath: srcPath)
            let fileType = attrs[.type] as? FileAttributeType
            let mode = ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644) & 0o777
            recordedModes[rel] = mode

            if fileType == .typeSymbolicLink {
                let dest = try fm.destinationOfSymbolicLink(atPath: srcPath)
                try fm.createSymbolicLink(atPath: dstURL.path, withDestinationPath: dest)
            } else if fileType == .typeDirectory {
                try fm.createDirectory(at: dstURL, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try Data(contentsOf: URL(fileURLWithPath: srcPath))
                try data.write(to: dstURL, options: .atomic)
            }
        }
    }

    private static func restoreDirectoryTreePreservingSymlinks(
        from backupRoot: URL,
        to targetRoot: URL,
        recordedModes: [String: Int],
        rootMode: Int?
    ) throws {
        let fm = FileManager.default
        let stdBackupPath = backupRoot.resolvingSymlinksInPath().standardizedFileURL.path
        try fm.createDirectory(at: targetRoot, withIntermediateDirectories: true)

        let relEntries = try DirectoryHasher.listRelativeEntries(under: backupRoot)

        var directoriesToModeFix: [(path: String, mode: Int)] = []

        for rel in relEntries {
            let srcPath = (stdBackupPath as NSString).appendingPathComponent(rel)
            let dstURL = targetRoot.appendingPathComponent(rel)
            let attrs = try fm.attributesOfItem(atPath: srcPath)
            let fileType = attrs[.type] as? FileAttributeType

            if fileType == .typeSymbolicLink {
                let dest = try fm.destinationOfSymbolicLink(atPath: srcPath)
                try fm.createSymbolicLink(atPath: dstURL.path, withDestinationPath: dest)
            } else if fileType == .typeDirectory {
                try fm.createDirectory(at: dstURL, withIntermediateDirectories: true)
                if let mode = recordedModes[rel] {
                    directoriesToModeFix.append((dstURL.path, mode))
                }
            } else {
                try fm.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try Data(contentsOf: URL(fileURLWithPath: srcPath))
                try AtomicFileWriter.writeAtomically(
                    bytes: data,
                    to: dstURL,
                    posixPermissions: recordedModes[rel]
                )
            }
        }

        // Apply directory permissions deepest-first, then root directory last.
        for entry in directoriesToModeFix.reversed() {
            try fm.setAttributes([.posixPermissions: entry.mode], ofItemAtPath: entry.path)
        }
        if let rootMode = recordedModes[""] ?? rootMode {
            try fm.setAttributes([.posixPermissions: rootMode], ofItemAtPath: targetRoot.path)
        }
    }
}

/// Same-directory temp-file + `replaceItemAt` atomic file writer preserving POSIX file permissions (`PLAN.md` §6.6 step 3).
enum AtomicFileWriter {
    static func writeAtomically(
        bytes: Data,
        to targetURL: URL,
        posixPermissions explicitPermissions: Int? = nil
    ) throws {
        let fm = FileManager.default
        let stdTarget = URL(fileURLWithPath: BackupManager.normalizeLexicalPath(targetURL.path))
        let parentDir = stdTarget.deletingLastPathComponent()
        if !DirectoryHasher.lstatExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        let targetExists = DirectoryHasher.lstatExists(atPath: stdTarget.path)
        let effectiveMode: Int
        if let explicitPermissions {
            effectiveMode = explicitPermissions & 0o777
        } else if targetExists,
            let attrs = try? fm.attributesOfItem(atPath: stdTarget.path),
            let existing = (attrs[.posixPermissions] as? NSNumber)?.intValue
        {
            effectiveMode = existing & 0o777
        } else {
            effectiveMode = 0o644
        }

        let tempURL = parentDir.appendingPathComponent(".bento-tmp-\(UUID().uuidString)")
        defer {
            if DirectoryHasher.lstatExists(atPath: tempURL.path) {
                try? fm.removeItem(at: tempURL)
            }
        }

        try bytes.write(to: tempURL)
        try fm.setAttributes([.posixPermissions: effectiveMode], ofItemAtPath: tempURL.path)

        if targetExists {
            _ = try fm.replaceItemAt(stdTarget, withItemAt: tempURL)
            try fm.setAttributes([.posixPermissions: effectiveMode], ofItemAtPath: stdTarget.path)
        } else {
            try fm.moveItem(at: tempURL, to: stdTarget)
            try fm.setAttributes([.posixPermissions: effectiveMode], ofItemAtPath: stdTarget.path)
        }
    }
}
