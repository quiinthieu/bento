import Foundation
import Testing

@testable import BentoCore

struct ProductTests {
    @Test("Product constants match Config/Product.xcconfig")
    func productMatchesXcconfig() throws {
        let configURL = Self.repositoryRoot().appendingPathComponent("Config/Product.xcconfig")
        let contents = try String(contentsOf: configURL, encoding: .utf8)
        let values = Self.parseXcconfig(contents)

        #expect(!Product.name.isEmpty)
        #expect(!Product.bundleID.isEmpty)
        #expect(!Product.cliName.isEmpty)
        #expect(!Product.supportDirName.isEmpty)
        #expect(!Product.version.isEmpty)
        #expect(!Product.buildNumber.isEmpty)

        #expect(values["BENTO_PRODUCT_NAME"] == Product.name)
        #expect(values["BENTO_BUNDLE_ID"] == Product.bundleID)
        #expect(values["BENTO_CLI_NAME"] == Product.cliName)
        #expect(values["BENTO_SUPPORT_DIR_NAME"] == Product.supportDirName)
        #expect(values["BENTO_VERSION"] == Product.version)
        #expect(values["BENTO_BUILD_NUMBER"] == Product.buildNumber)
        #expect(contents.contains("#include? \"Signing.xcconfig\""))
    }

    @Test("Product display and CLI names are not hardcoded outside Product.swift")
    func noHardcodedProductNameInSources() throws {
        let sourcesDir = Self.repositoryRoot().appendingPathComponent("Sources")
        let productFile = sourcesDir.appendingPathComponent("BentoCore/Product.swift").standardizedFileURL
        let enumerator = FileManager.default.enumerator(at: sourcesDir, includingPropertiesForKeys: nil)

        let forbiddenLiterals = [
            "\"\(Product.name)\"",
            "\"\(Product.cliName)\"",
            "\"\(Product.bundleID)\""
        ]

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            guard fileURL.standardizedFileURL != productFile else { continue }
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            for literal in forbiddenLiterals {
                #expect(
                    !contents.contains(literal),
                    "Hardcoded literal \(literal) found in \(fileURL.path); use Product.* instead"
                )
            }
        }
    }

    @Test("CLI help abstract updates when product name changes and binary --help uses Product")
    func cliHelpReflectsProductMetadata() throws {
        let defaultAbstract = Product.cliHelpAbstract()
        #expect(defaultAbstract.contains(Product.name))

        let renamedAbstract = Product.cliHelpAbstract(productName: "RenamedInspector")
        #expect(renamedAbstract.contains("RenamedInspector"))
        #expect(!renamedAbstract.contains(Product.name))

        let cliBinary = try Self.locateBuiltCLIBinary()
        let process = Process()
        process.executableURL = cliBinary
        process.arguments = ["--help"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let helpOutput = String(decoding: data, as: UTF8.self)
        #expect(helpOutput.contains(Product.name))
        #expect(helpOutput.contains("USAGE: \(Product.cliName)"))
    }

    private static func locateBuiltCLIBinary() throws -> URL {
        let bundleURL = Bundle(for: BundleAnchor.self).bundleURL
        let buildDir = bundleURL.deletingLastPathComponent()
        let siblingBinary = buildDir.appendingPathComponent(Product.cliName)
        if FileManager.default.isExecutableFile(atPath: siblingBinary.path) {
            return siblingBinary
        }

        let debugBinary = repositoryRoot()
            .appendingPathComponent(".build/debug")
            .appendingPathComponent(Product.cliName)
        if FileManager.default.isExecutableFile(atPath: debugBinary.path) {
            return debugBinary
        }

        throw CocoaError(.fileNoSuchFile)
    }

    private static func parseXcconfig(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let withoutComment = rawLine.components(separatedBy: "//").first ?? ""
            let trimmed = withoutComment.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let equalsIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equalsIndex].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private final class BundleAnchor {}
