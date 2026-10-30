import BentoCore
import BentoParsing
import BentoTestSupport
import Foundation
import Testing

@Suite("Frontmatter and MDC Parser Tests")
struct FrontmatterAndMDCParserTests {
    @Test("Parses valid YAML frontmatter, preserves quoted vs typed scalars, and records bodyStartLine")
    func parsesValidYAMLFrontmatter() {
        let source = """
            ---
            name: code-review
            description: "true"
            enabled: true
            priority: 2
            tags:
              - swift
              - lint
            ---
            # Code Review Skill

            - Check concurrency safety.
            """

        let doc = FrontmatterParser.parse(source)
        #expect(doc.diagnostics.isEmpty)
        #expect(doc.bodyStartLine == 10)
        #expect(doc.frontmatter?["name"] == .string("code-review"))
        #expect(doc.frontmatter?["description"] == .string("true"))
        #expect(doc.frontmatter?["enabled"] == .bool(true))
        #expect(doc.frontmatter?["priority"] == .int(2))
        #expect(doc.frontmatter?["tags"] == .array([.string("swift"), .string("lint")]))
        #expect(doc.body.hasPrefix("# Code Review Skill"))
    }

    @Test("Documents without frontmatter return nil frontmatter and bodyStartLine 1")
    func handlesNoFrontmatter() {
        let plain = "# Plain Rules\n\n- Keep commits atomic.\n"
        let doc = FrontmatterParser.parse(plain)
        #expect(doc.frontmatter == nil)
        #expect(doc.body == plain)
        #expect(doc.bodyStartLine == 1)
        #expect(doc.diagnostics.isEmpty)
    }

    @Test("Parses Cursor .mdc from polyglot (array globs, alwaysApply) and hostile (unquoted leading-* globs)")
    func parsesPolyglotAndHostileMDC() throws {
        let polyglot = try FixtureHome(scenario: "polyglot")
        let styleData = try polyglot.makeEnvironment().fileSystem.contents(
            at: polyglot.url.appendingPathComponent("repos/demo-app/.cursor/rules/style.mdc")
        )
        let styleMDC = try MDCParser.parse(styleData)
        #expect(styleMDC.diagnostics.isEmpty)
        #expect(styleMDC.description == "Code style guidelines")
        #expect(styleMDC.globs == ["**/*.ts"])
        #expect(styleMDC.alwaysApply)
        #expect(styleMDC.effectiveLoadMode == .always)
        #expect(styleMDC.bodyStartLine == 6)
        #expect(styleMDC.rulesDoc.content.contains("Use spaces for indentation"))

        let hostile = try FixtureHome(scenario: "hostile")
        let unquotedData = try hostile.makeEnvironment().fileSystem.contents(
            at: hostile.url.appendingPathComponent("cursor/unquoted-glob.mdc")
        )
        let unquotedMDC = try MDCParser.parse(unquotedData)
        #expect(unquotedMDC.diagnostics.isEmpty)
        #expect(unquotedMDC.description == "Swift concurrency and formatting rules")
        #expect(unquotedMDC.globs == ["*.swift", "Sources/**/*.swift"])
        #expect(!unquotedMDC.alwaysApply)
        #expect(unquotedMDC.effectiveLoadMode == .conditional(globs: ["*.swift", "Sources/**/*.swift"]))
        #expect(unquotedMDC.bodyStartLine == 6)
    }

    @Test("Hostile unclosed frontmatter, invalid YAML frontmatter, and invalid UTF-8 fail gracefully")
    func handlesHostileMalformedFrontmatterAndInvalidUTF8() throws {
        let hostile = try FixtureHome(scenario: "hostile")
        let fs = hostile.makeEnvironment().fileSystem

        let unclosedData = try fs.contents(
            at: hostile.url.appendingPathComponent("markdown/unclosed-frontmatter.md")
        )
        let unclosedDoc = try FrontmatterParser.parse(unclosedData)
        #expect(unclosedDoc.frontmatter == nil)
        #expect(!unclosedDoc.diagnostics.isEmpty)
        #expect(unclosedDoc.body.contains("Body line that never gets a frontmatter terminator."))

        let invalidYAMLData = try fs.contents(
            at: hostile.url.appendingPathComponent("markdown/invalid-yaml-frontmatter.md")
        )
        let invalidYAMLDoc = try FrontmatterParser.parse(invalidYAMLData)
        #expect(invalidYAMLDoc.frontmatter == nil)
        #expect(!invalidYAMLDoc.diagnostics.isEmpty)
        #expect(invalidYAMLDoc.body.contains("# Recovered Body"))
        #expect(invalidYAMLDoc.bodyStartLine == 5)

        let invalidUTF8Data = try fs.contents(
            at: hostile.url.appendingPathComponent("markdown/invalid-utf8.md")
        )
        #expect(throws: BentoParsingError.invalidUTF8) {
            _ = try FrontmatterParser.parse(invalidUTF8Data)
        }
    }
}
