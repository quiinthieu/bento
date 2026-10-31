import Foundation

/// Abstraction over moving deleted items to the Trash (`PLAN.md` §6.6 step 4).
public protocol TrashHandling: Sendable {
    /// Moves `url` into the Trash and returns its resulting location inside the Trash.
    @discardableResult
    func trashItem(at url: URL) throws -> URL
}

/// Production Trash handler delegating exclusively to `FileManager.trashItem(at:resultingItemURL:)`.
public struct SystemTrashHandler: TrashHandling {
    public init() {}

    @discardableResult
    public func trashItem(at url: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return (resultingURL as URL?) ?? url
    }
}

/// Hermetic Trash handler moving items into an isolated directory during `--home` runs and unit tests
/// so real `~/.Trash` is never touched (`PLAN.md` §0 Rule 3).
public struct HermeticTrashHandler: TrashHandling {
    public let trashDirectory: URL

    public init(trashDirectory: URL) {
        self.trashDirectory = trashDirectory.standardizedFileURL
    }

    @discardableResult
    public func trashItem(at url: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        let baseName = url.lastPathComponent
        var candidate = trashDirectory.appendingPathComponent(baseName)
        if Self.lstatExists(atPath: candidate.path) {
            candidate = trashDirectory.appendingPathComponent("\(UUID().uuidString)-\(baseName)")
        }
        try fm.moveItem(at: url, to: candidate)
        return candidate
    }

    private static func lstatExists(atPath path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }
}
