import BentoCore
import BentoParsing
import BentoTestSupport
import Foundation
import Testing

@Suite("ImportResolver Tests")
struct ImportResolverTests {
    @Test("Resolves relative, @~/ fixture-home, and backslash-escaped space paths while ignoring code & decorators")
    func resolvesValidImportsAndReportsBrokenAndSymlinkLoops() throws {
        let hostile = try FixtureHome(scenario: "hostile")
        let env = hostile.makeEnvironment()
        let rootURL = hostile.url.appendingPathComponent("imports/broken-and-codeblocks.md")

        let resolver = ImportResolver(syntax: .claudeCode, maxDepth: 5)
        let resolution = resolver.resolve(
            rootURL: rootURL,
            homeURL: env.home,
            fileSystem: env.fileSystem
        )

        #expect(
            resolution.directImports == [
                "./leaf.md",
                "~/home-rule.md",
                "./dir with spaces/spaced-rule.md",
                "./does-not-exist.md",
                "./symlink-loop-a.md"
            ]
        )

        // Expanded content includes the three valid imported files and never touches real $HOME.
        #expect(resolution.expandedContent.contains("Keep functions small and well-tested."))
        #expect(resolution.expandedContent.contains("Never commit credentials or personal tokens."))
        #expect(resolution.expandedContent.contains("Escape spaces with a backslash in import paths."))
        #expect(resolution.resolvedFiles.count == 3)
        for resolvedURL in resolution.resolvedFiles {
            #expect(resolvedURL.standardizedFileURL.path.hasPrefix(hostile.url.standardizedFileURL.path))
        }

        // Missing file and symlink loop both produce non-fatal diagnostics.
        #expect(resolution.diagnostics.count == 2)
        let codes = Set(resolution.diagnostics.map(\.code))
        #expect(codes.contains("import.broken"))
    }

    @Test("Detects mutual import cycles without infinite recursion")
    func detectsImportCycles() throws {
        let hostile = try FixtureHome(scenario: "hostile")
        let env = hostile.makeEnvironment()
        let cycleA = hostile.url.appendingPathComponent("imports/cycle-a.md")

        let resolution = ImportResolver(syntax: .gemini, maxDepth: 5).resolve(
            rootURL: cycleA,
            homeURL: env.home,
            fileSystem: env.fileSystem
        )

        #expect(resolution.expandedContent.contains("Rule in cycle A."))
        #expect(resolution.expandedContent.contains("Rule in cycle B."))
        #expect(resolution.diagnostics.contains { $0.code == "import.cycle" })
    }

    @Test("Enforces maxDepth limit on deep import chains")
    func enforcesMaxDepth() throws {
        let hostile = try FixtureHome(scenario: "hostile")
        let env = hostile.makeEnvironment()
        let depth0 = hostile.url.appendingPathComponent("imports/depth-0.md")

        let resolution = ImportResolver(syntax: .claudeCode, maxDepth: 5).resolve(
            rootURL: depth0,
            homeURL: env.home,
            fileSystem: env.fileSystem
        )

        // depth-0 (hop 0) -> depth-1 (1) -> depth-2 (2) -> depth-3 (3) -> depth-4 (4) -> depth-5 (5)
        // depth-5's import of depth-6 exceeds maxDepth = 5.
        #expect(resolution.expandedContent.contains("Depth 5 rule."))
        #expect(!resolution.expandedContent.contains("Depth 6 rule"))
        #expect(resolution.diagnostics.contains { $0.code == "import.maxDepthExceeded" })
    }

    @Test("Allows diamond imports without false cycle diagnostics and handles chmod 000 unreadable target")
    func handlesDiamondImportsAndUnreadableFile() throws {
        let hostile = try FixtureHome(scenario: "hostile")
        let tempHome = try hostile.copyToTemporaryDirectory()
        let lockedURL = tempHome.appendingPathComponent("imports/unreadable.md")
        defer {
            _ = chmod(lockedURL.path, 0o644)
            try? FileManager.default.removeItem(at: tempHome)
        }

        let importsDir = tempHome.appendingPathComponent("imports", isDirectory: true)
        let sharedURL = importsDir.appendingPathComponent("shared.md")
        let branch1URL = importsDir.appendingPathComponent("branch1.md")
        let branch2URL = importsDir.appendingPathComponent("branch2.md")
        let diamondRootURL = importsDir.appendingPathComponent("diamond-root.md")

        try "- Shared diamond rule.\n".write(to: sharedURL, atomically: true, encoding: .utf8)
        try "- Branch 1.\n@./shared.md\n".write(to: branch1URL, atomically: true, encoding: .utf8)
        try "- Branch 2.\n@./shared.md\n".write(to: branch2URL, atomically: true, encoding: .utf8)
        try "- Secret locked.\n".write(to: lockedURL, atomically: true, encoding: .utf8)
        #expect(chmod(lockedURL.path, 0o000) == 0)

        try "@./branch1.md\n@./branch2.md\n@./unreadable.md\n".write(
            to: diamondRootURL,
            atomically: true,
            encoding: .utf8
        )

        let fs = LocalReadOnlyFileSystem()
        let resolution = ImportResolver(syntax: .claudeCode, maxDepth: 5).resolve(
            rootURL: diamondRootURL,
            homeURL: tempHome,
            fileSystem: fs
        )

        #expect(!resolution.diagnostics.contains { $0.code == "import.cycle" })
        #expect(resolution.diagnostics.contains { $0.code == "import.broken" })
        #expect(resolution.expandedContent.contains("Shared diamond rule."))
    }
}
