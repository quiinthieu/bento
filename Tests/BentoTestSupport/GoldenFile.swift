import Foundation

/// Errors thrown by `GoldenFile` during snapshot comparison.
public enum GoldenFileError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Expected golden JSON file does not exist on disk and recording is disabled.
    case missingGoldenFile(path: String)
    /// Encoded JSON differed from the checked-in golden JSON file.
    case mismatch(path: String, firstDifferingLine: Int, expectedLine: String, actualLine: String)

    public var description: String {
        switch self {
        case .missingGoldenFile(let path):
            return "Missing golden file at \(path). Re-run with RECORD_GOLDEN=1 swift test to record."
        case .mismatch(let path, let line, let expected, let actual):
            return """
                Golden mismatch in \(path) at line \(line):
                  expected: \(expected)
                  actual:   \(actual)
                """
        }
    }
}

/// Deterministic JSON golden-file recorder and comparator supporting `RECORD_GOLDEN=1`.
public enum GoldenFile {
    /// Encodes `value` deterministically, normalizes `homeURL` paths to `<HOME>`, and either
    /// records (`record == true` or `RECORD_GOLDEN=1`) or compares against `goldenURL`.
    public static func assertMatches<T: Encodable>(
        _ value: T,
        goldenURL: URL,
        homeURL: URL? = nil,
        record: Bool? = nil
    ) throws {
        let shouldRecord = record ?? (ProcessInfo.processInfo.environment["RECORD_GOLDEN"] == "1")
        let actualJSON = try encodeCanonicalJSON(value, homeURL: homeURL)

        if shouldRecord {
            let parentDir = goldenURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try Data(actualJSON.utf8).write(to: goldenURL, options: [.atomic])
            return
        }

        guard FileManager.default.fileExists(atPath: goldenURL.path) else {
            throw GoldenFileError.missingGoldenFile(path: goldenURL.path)
        }

        let expectedJSON = try String(contentsOf: goldenURL, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")

        guard expectedJSON != actualJSON else { return }

        let expectedLines = expectedJSON.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let actualLines = actualJSON.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let maxLines = max(expectedLines.count, actualLines.count)

        for idx in 0..<maxLines {
            let exp = idx < expectedLines.count ? String(expectedLines[idx]) : "<EOF>"
            let act = idx < actualLines.count ? String(actualLines[idx]) : "<EOF>"
            if exp != act {
                throw GoldenFileError.mismatch(
                    path: goldenURL.path,
                    firstDifferingLine: idx + 1,
                    expectedLine: exp,
                    actualLine: act
                )
            }
        }
    }

    /// Produces sorted-key, pretty-printed, ISO-8601 JSON with `<HOME>` path normalization and trailing newline.
    public static func encodeCanonicalJSON<T: Encodable>(_ value: T, homeURL: URL? = nil) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(value)
        var text = String(decoding: data, as: UTF8.self)

        if let homeURL {
            let rawPath = homeURL.standardizedFileURL.path
            let resolvedPath = homeURL.resolvingSymlinksInPath().standardizedFileURL.path
            // Replace longer prefix first in case resolvedPath contains rawPath (e.g. /private/var vs /var).
            let prefixes = Set([rawPath, resolvedPath]).sorted { $0.count > $1.count }
            for prefix in prefixes where !prefix.isEmpty {
                text = text.replacingOccurrences(of: prefix, with: "<HOME>")
            }
        }

        if !text.hasSuffix("\n") {
            text.append("\n")
        }
        return text
    }
}
