import Foundation
import Testing

@testable import BentoCore

struct ReleasePackagingTests {
    @Test("Scripts/bump-version.sh --verify succeeds on synchronized repo metadata")
    func bumpVersionVerifyPassesOnRepository() throws {
        let root = Self.repositoryRoot()
        let script = root.appendingPathComponent("Scripts/bump-version.sh")
        #expect(FileManager.default.isExecutableFile(atPath: script.path))

        let result = try Self.runScript(script, arguments: ["--verify"])
        #expect(result.exitCode == 0, "Expected --verify to succeed: \(result.stderr)")
    }

    @Test("Scripts/bump-version.sh updates single-source metadata and detects drift on temp copy")
    func bumpVersionUpdatesAndDetectsDriftInHermeticCopy() throws {
        let root = Self.repositoryRoot()
        let script = root.appendingPathComponent("Scripts/bump-version.sh")

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-bump-version-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let tempConfigDir = tempRoot.appendingPathComponent("Config", isDirectory: true)
        let tempCoreDir = tempRoot.appendingPathComponent("Sources/BentoCore", isDirectory: true)
        try FileManager.default.createDirectory(at: tempConfigDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempCoreDir, withIntermediateDirectories: true)

        let tempXcconfig = tempConfigDir.appendingPathComponent("Product.xcconfig")
        let tempProductSwift = tempCoreDir.appendingPathComponent("Product.swift")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("Config/Product.xcconfig"),
            to: tempXcconfig
        )
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("Sources/BentoCore/Product.swift"),
            to: tempProductSwift
        )

        let updateResult = try Self.runScript(
            script,
            arguments: ["--root", tempRoot.path, "0.2.0", "42"]
        )
        #expect(updateResult.exitCode == 0, "Update failed: \(updateResult.stderr)")

        let xcconfigText = try String(contentsOf: tempXcconfig, encoding: .utf8)
        let productSwiftText = try String(contentsOf: tempProductSwift, encoding: .utf8)
        #expect(xcconfigText.contains("BENTO_VERSION = 0.2.0"))
        #expect(xcconfigText.contains("BENTO_BUILD_NUMBER = 42"))
        #expect(productSwiftText.contains("public static let version = \"0.2.0\""))
        #expect(productSwiftText.contains("public static let buildNumber = \"42\""))

        let verifyAfterUpdate = try Self.runScript(
            script,
            arguments: ["--root", tempRoot.path, "--verify"]
        )
        #expect(verifyAfterUpdate.exitCode == 0)

        let drifted = xcconfigText.replacingOccurrences(
            of: "BENTO_VERSION = 0.2.0",
            with: "BENTO_VERSION = 0.2.1"
        )
        try drifted.write(to: tempXcconfig, atomically: true, encoding: .utf8)

        let verifyDrift = try Self.runScript(
            script,
            arguments: ["--root", tempRoot.path, "--verify"]
        )
        #expect(verifyDrift.exitCode != 0)
    }

    @Test("Config/Bento.entitlements explicitly disables App Sandbox for Hardened Runtime")
    func entitlementsDisableAppSandboxForHardenedRuntime() throws {
        let entitlementsURL = Self.repositoryRoot().appendingPathComponent("Config/Bento.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let dict = try #require(plist as? [String: Any])

        let sandbox = dict["com.apple.security.app-sandbox"] as? Bool
        #expect(sandbox == false)
        #expect((dict["com.apple.security.cs.disable-library-validation"] as? Bool) != true)
        #expect((dict["com.apple.security.cs.allow-unsigned-executable-memory"] as? Bool) != true)
    }

    @Test("Homebrew cask template renders valid agent-bento cask with SHA-256 and embedded CLI binary")
    func homebrewCaskTemplateRendersCleanly() throws {
        let root = Self.repositoryRoot()
        let templateURL = root.appendingPathComponent("Casks/agent-bento.rb.template")
        let renderScript = root.appendingPathComponent("Scripts/render-cask.sh")
        #expect(FileManager.default.fileExists(atPath: templateURL.path))
        #expect(FileManager.default.isExecutableFile(atPath: renderScript.path))

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-cask-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dummyDMG = tempDir.appendingPathComponent("\(Product.name)-\(Product.version).dmg")
        let payload = Data("synthetic-dmg-payload-for-sha256".utf8)
        try payload.write(to: dummyDMG)
        let expectedSHA = ContentHasher.sha256Hex(payload)

        let renderedCask = tempDir.appendingPathComponent("agent-bento.rb")
        let downloadURL =
            "https://github.com/quiinthieu/bento/releases/download/v\(Product.version)/\(dummyDMG.lastPathComponent)"
        let result = try Self.runScript(
            renderScript,
            arguments: [
                "--dmg", dummyDMG.path,
                "--url", downloadURL,
                "--output", renderedCask.path
            ]
        )
        #expect(result.exitCode == 0, "render-cask.sh failed: \(result.stderr)")

        let caskContents = try String(contentsOf: renderedCask, encoding: .utf8)
        #expect(caskContents.contains("cask \"agent-bento\" do"))
        #expect(caskContents.contains("version \"\(Product.version)\""))
        #expect(caskContents.contains("sha256 \"\(expectedSHA)\""))
        #expect(caskContents.contains("url \"\(downloadURL)\""))
        #expect(caskContents.contains("depends_on macos: :sequoia"))
        #expect(caskContents.contains("app \"\(Product.name).app\""))
        #expect(caskContents.contains("binary \"#{appdir}/\(Product.name).app/Contents/Helpers/\(Product.cliName)\""))
        #expect(!caskContents.contains("{{"))
    }

    @Test("Sparkle appcast generator produces valid EdDSA feed XML and enforces signature when required")
    func sparkleAppcastGeneratorEmitsEdDSAReadyFeed() throws {
        let root = Self.repositoryRoot()
        let script = root.appendingPathComponent("Scripts/generate-appcast.sh")
        #expect(FileManager.default.isExecutableFile(atPath: script.path))

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-appcast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dummyDMG = tempDir.appendingPathComponent("\(Product.name)-\(Product.version).dmg")
        let payload = Data(repeating: 0x42, count: 2048)
        try payload.write(to: dummyDMG)

        let appcastURL = tempDir.appendingPathComponent("appcast.xml")
        let downloadURL =
            "https://github.com/quiinthieu/bento/releases/download/v\(Product.version)/\(dummyDMG.lastPathComponent)"

        let missingSigResult = try Self.runScript(
            script,
            arguments: [
                "--dmg", dummyDMG.path,
                "--download-url", downloadURL,
                "--output", appcastURL.path,
                "--require-signature"
            ]
        )
        #expect(missingSigResult.exitCode != 0)

        let signedResult = try Self.runScript(
            script,
            arguments: [
                "--dmg", dummyDMG.path,
                "--download-url", downloadURL,
                "--ed-signature", "dGVzdEVkRFNBU2lnbmF0dXJl Base64==",
                "--output", appcastURL.path,
                "--require-signature"
            ]
        )
        #expect(signedResult.exitCode == 0, "generate-appcast.sh failed: \(signedResult.stderr)")

        let xmlData = try Data(contentsOf: appcastURL)
        let xmlParser = XMLParser(data: xmlData)
        #expect(xmlParser.parse(), "Generated appcast.xml must be well-formed XML")

        let xmlText = String(decoding: xmlData, as: UTF8.self)
        #expect(xmlText.contains("sparkle:version=\"\(Product.buildNumber)\""))
        #expect(xmlText.contains("sparkle:shortVersionString=\"\(Product.version)\""))
        #expect(xmlText.contains("sparkle:edSignature=\"dGVzdEVkRFNBU2lnbmF0dXJl Base64==\""))
        #expect(xmlText.contains("length=\"2048\""))
        #expect(xmlText.contains("url=\"\(downloadURL)\""))
    }

    @Test("Release workflow, README privacy section, MIT LICENSE, and THIRD_PARTY_NOTICES exist")
    func releaseWorkflowAndLegalDocsExistAndMeetRequirements() throws {
        let root = Self.repositoryRoot()

        let makeDMG = root.appendingPathComponent("Scripts/make-dmg.sh")
        let notarize = root.appendingPathComponent("Scripts/notarize.sh")
        let embedCLI = root.appendingPathComponent("Scripts/embed-cli.sh")
        #expect(FileManager.default.isExecutableFile(atPath: makeDMG.path))
        #expect(FileManager.default.isExecutableFile(atPath: notarize.path))
        #expect(FileManager.default.isExecutableFile(atPath: embedCLI.path))

        let releaseWorkflow = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )
        #expect(releaseWorkflow.contains("v*"))
        #expect(releaseWorkflow.contains("Scripts/make-dmg.sh"))
        #expect(releaseWorkflow.contains("Scripts/notarize.sh"))
        #expect(releaseWorkflow.contains("Scripts/bump-version.sh --verify"))

        let license = try String(
            contentsOf: root.appendingPathComponent("LICENSE"),
            encoding: .utf8
        )
        #expect(license.contains("MIT License"))
        #expect(license.contains("Copyright (c) 2026 Uyen Thieu"))

        let notices = try String(
            contentsOf: root.appendingPathComponent("THIRD_PARTY_NOTICES.md"),
            encoding: .utf8
        )
        for dependency in [
            "GRDB.swift",
            "swift-argument-parser",
            "TOMLDecoder",
            "Yams",
            "Zstandard",
            "tiktoken",
            "Sparkle"
        ] {
            #expect(notices.contains(dependency), "Missing \(dependency) in THIRD_PARTY_NOTICES.md")
        }

        let readme = try String(
            contentsOf: root.appendingPathComponent("README.md"),
            encoding: .utf8
        )
        #expect(readme.contains("## Privacy"))
        #expect(readme.localizedCaseInsensitiveContains("telemetry"))
        #expect(readme.contains("Keychain"))
        #expect(readme.contains("Sparkle"))
        #expect(readme.contains("agent-bento"))
    }

    private struct ScriptResult {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    private static func runScript(_ scriptURL: URL, arguments: [String]) throws -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path] + arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ScriptResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
