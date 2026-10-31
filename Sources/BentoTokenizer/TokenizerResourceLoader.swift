import Foundation

/// Safe, `fatalError`-free vocabulary loader searching app/CLI bundles and repository `Resources/tokenizers/`.
public enum TokenizerResourceLoader: Sendable {
    private static let bundleNames = [
        "Bento_BentoTokenizer.bundle",
        "BentoPackage_BentoTokenizer.bundle"
    ]

    /// Loads the raw `.tiktoken` merge table bytes for `encoding`.
    public static func loadVocabularyData(for encoding: BPEEncoding) throws -> Data {
        let deflateFileName = "\(encoding.rawValue).tiktoken.deflate"
        let plainFileName = "\(encoding.rawValue).tiktoken"

        for dir in candidateResourceDirectories() {
            let deflateURL = dir.appendingPathComponent(deflateFileName)
            if FileManager.default.isReadableFile(atPath: deflateURL.path),
                let compressed = try? Data(contentsOf: deflateURL)
            {
                do {
                    return try (compressed as NSData).decompressed(using: .zlib) as Data
                } catch {
                    throw BentoTokenizerError.vocabularyDecompressionFailed(encoding.rawValue)
                }
            }

            let plainURL = dir.appendingPathComponent(plainFileName)
            if FileManager.default.isReadableFile(atPath: plainURL.path),
                let plain = try? Data(contentsOf: plainURL)
            {
                return plain
            }
        }

        throw BentoTokenizerError.missingVocabularyResource(encoding.rawValue)
    }

    private static func candidateResourceDirectories() -> [URL] {
        var dirs: [URL] = []

        func appendBundleCandidates(around baseURL: URL) {
            for bundleName in bundleNames {
                let bundleURL = baseURL.appendingPathComponent(bundleName, isDirectory: true)
                dirs.append(bundleURL.appendingPathComponent("Resources", isDirectory: true))
                dirs.append(bundleURL.appendingPathComponent("Contents/Resources/Resources", isDirectory: true))
                dirs.append(bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true))
                dirs.append(bundleURL)
            }
            dirs.append(baseURL.appendingPathComponent("Resources", isDirectory: true))
            dirs.append(baseURL)
        }

        if let mainResourceURL = Bundle.main.resourceURL {
            appendBundleCandidates(around: mainResourceURL)
        }
        appendBundleCandidates(around: Bundle.main.bundleURL)

        // Support embedded CLI helper at `<App>.app/Contents/Helpers/<cli>` (including via PATH symlinks) looking into `../Resources/`.
        if let mainExecDir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            appendBundleCandidates(around: mainExecDir)
            appendBundleCandidates(
                around: mainExecDir.deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true)
            )
        }
        let executableURL = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        appendBundleCandidates(around: executableURL)
        appendBundleCandidates(
            around: executableURL.deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true)
        )

        // Support XCTest / Swift Testing bundles inside `.build/<triple>/debug/`.
        let anchorBundleURL = Bundle(for: BundleAnchor.self).bundleURL
        appendBundleCandidates(around: anchorBundleURL.deletingLastPathComponent())

        // Development & source-checkout fallback (`Resources/tokenizers/` and `Sources/BentoTokenizer/Resources/`).
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        dirs.append(sourceRoot.appendingPathComponent("Sources/BentoTokenizer/Resources", isDirectory: true))
        dirs.append(sourceRoot.appendingPathComponent("Resources/tokenizers", isDirectory: true))

        return dirs
    }
}

private final class BundleAnchor {}
