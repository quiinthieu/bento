import BentoCore
import BentoTestSupport
import Foundation
import Testing

struct ReadOnlyFileSystemTests {
    @Test("FixtureHome loads empty and polyglot homes without touching real $HOME")
    func fixtureHomesLoadCleanly() throws {
        let realHome = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        let emptyHome = try FixtureHome(scenario: "empty")
        let polyglotHome = try FixtureHome(scenario: "polyglot")

        #expect(emptyHome.url.standardizedFileURL.path != realHome)
        #expect(polyglotHome.url.standardizedFileURL.path != realHome)

        let emptyEnv = emptyHome.makeEnvironment()
        #expect(emptyEnv.fileSystem.exists(emptyHome.url))
        #expect(!emptyEnv.fileSystem.exists(emptyHome.url.appendingPathComponent(".claude")))

        let polyglotEnv = polyglotHome.makeEnvironment()
        let claudeRules = polyglotHome.url.appendingPathComponent(".claude/CLAUDE.md")
        #expect(polyglotEnv.fileSystem.exists(claudeRules))

        let data = try polyglotEnv.fileSystem.contents(at: claudeRules)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("Global Claude Instructions"))

        let demoRepo = polyglotHome.url.appendingPathComponent("repos/demo-app")
        let repoEntries = try polyglotEnv.fileSystem.list(demoRepo).map(\.lastPathComponent)
        #expect(repoEntries == repoEntries.sorted())
        #expect(repoEntries.contains("AGENTS.md"))
        #expect(repoEntries.contains("CLAUDE.md"))
        #expect(repoEntries.contains("GEMINI.md"))
    }

    @Test("LocalReadOnlyFileSystem reports accurate attributes and symlink resolution")
    func attributesAndSymlinks() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-rofs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetURL = tempDir.appendingPathComponent("target.md")
        let payload = Data("hello world\n".utf8)
        try payload.write(to: targetURL)

        let linkURL = tempDir.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        let fs = LocalReadOnlyFileSystem()
        #expect(fs.exists(targetURL))
        #expect(fs.exists(linkURL))
        #expect(!fs.exists(tempDir.appendingPathComponent("missing.md")))

        let targetAttrs = try fs.attributes(targetURL)
        #expect(targetAttrs.size == UInt64(payload.count))
        #expect(!targetAttrs.isSymlink)
        #expect(!targetAttrs.isDirectory)
        #expect(targetAttrs.inode > 0)

        let linkAttrs = try fs.attributes(linkURL)
        #expect(linkAttrs.isSymlink)
        #expect(!linkAttrs.isDirectory)

        let dirAttrs = try fs.attributes(tempDir)
        #expect(dirAttrs.isDirectory)
        #expect(!dirAttrs.isSymlink)

        #expect(
            fs.resolveSymlinks(linkURL).standardizedFileURL == targetURL.resolvingSymlinksInPath().standardizedFileURL)
    }
}
