import BentoCore
import BentoTestSupport
import Foundation
import Testing

struct GoldenFileTests {
    @Test("GoldenFile records, normalizes <HOME> paths, compares matches, and flags diffs")
    func goldenRecordAndCompare() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bento-golden-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fakeHome = URL(fileURLWithPath: "/Users/example/Fixtures/homes/polyglot")
        let goldenURL = tempDir.appendingPathComponent("__golden__/sample.json")

        let location = SourceLocation(
            path: "/Users/example/Fixtures/homes/polyglot/.claude/CLAUDE.md",
            realPath: "/Users/example/Fixtures/homes/polyglot/.claude/CLAUDE.md",
            lineRange: 1...4
        )

        // Missing file without record=true must throw missingGoldenFile.
        #expect(throws: GoldenFileError.self) {
            try GoldenFile.assertMatches(location, goldenURL: goldenURL, homeURL: fakeHome, record: false)
        }

        // Recording creates parent directory and normalizes home prefix to <HOME>.
        try GoldenFile.assertMatches(location, goldenURL: goldenURL, homeURL: fakeHome, record: true)
        let savedJSON = try String(contentsOf: goldenURL, encoding: .utf8)
        #expect(savedJSON.contains("<HOME>/.claude/CLAUDE.md"))
        #expect(!savedJSON.contains("/Users/example"))

        // Comparing against identical data from a different checkout path must pass!
        let ciHome = URL(fileURLWithPath: "/Users/runner/work/bento/Fixtures/homes/polyglot")
        let ciLocation = SourceLocation(
            path: "/Users/runner/work/bento/Fixtures/homes/polyglot/.claude/CLAUDE.md",
            realPath: "/Users/runner/work/bento/Fixtures/homes/polyglot/.claude/CLAUDE.md",
            lineRange: 1...4
        )
        try GoldenFile.assertMatches(ciLocation, goldenURL: goldenURL, homeURL: ciHome, record: false)

        // Comparing against mutated data must throw mismatch.
        let mutated = SourceLocation(
            path: "/Users/runner/work/bento/Fixtures/homes/polyglot/.claude/CLAUDE.md",
            realPath: "/Users/runner/work/bento/Fixtures/homes/polyglot/.claude/CLAUDE.md",
            lineRange: 1...99
        )
        #expect(throws: GoldenFileError.self) {
            try GoldenFile.assertMatches(mutated, goldenURL: goldenURL, homeURL: ciHome, record: false)
        }
    }

    @Test("Checked-in polyglot sample golden matches deterministic encoding")
    func checkedInPolyglotGoldenMatches() throws {
        let polyglot = try FixtureHome(scenario: "polyglot")
        let claudeFile = polyglot.url.appendingPathComponent(".claude/CLAUDE.md")
        let env = polyglot.makeEnvironment()
        let bytes = try env.fileSystem.contents(at: claudeFile)
        let text = String(decoding: bytes, as: UTF8.self)

        let artifact = Artifact(
            id: ArtifactID(
                agent: .claudeCode,
                kind: .rules,
                scope: .user,
                path: "<HOME>/.claude/CLAUDE.md"
            ),
            agent: .claudeCode,
            kind: .rules,
            scope: .user,
            name: "CLAUDE.md",
            location: SourceLocation(
                path: claudeFile.path,
                realPath: env.fileSystem.resolveSymlinks(claudeFile).path
            ),
            contentHash: ContentHasher.sha256NormalizedText(text),
            enabled: true,
            loadMode: .always,
            payload: .rules(
                RulesDoc(
                    content: text,
                    imports: [],
                    frontmatter: nil,
                    byteCount: bytes.count,
                    characterCount: text.count,
                    wasTruncated: false
                )
            ),
            diagnostics: []
        )

        let goldenURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("__golden__/polyglot-user-claude-md.json")
        try GoldenFile.assertMatches(artifact, goldenURL: goldenURL, homeURL: polyglot.url)
    }
}
