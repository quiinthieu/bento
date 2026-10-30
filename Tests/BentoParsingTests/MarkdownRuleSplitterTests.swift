import BentoCore
import BentoParsing
import Foundation
import Testing

@Suite("MarkdownRuleSplitter Tests")
struct MarkdownRuleSplitterTests {
    @Test("Splits headings, bullets, numbered items, and multi-sentence paragraphs while skipping code blocks")
    func splitsUnitsWithAccurateHeadingsAndLineRanges() {
        let doc = """
            ---
            description: Sample rule doc
            ---
            # Coding Standards

            ## Formatting
            - Use **4 spaces** for indentation in `*.swift` files.
              Continuation line of the first bullet.
            - Prefer [Swift Testing](https://developer.apple.com/xcode/swift-testing/) over XCTest.

            ```sh
            # This bash comment must not alter headingPath or become a rule unit
            - echo "not a bullet"
            ```

            ## Workflow
            1. Write failing tests in `Tests/` first.
            2. Run `swift test` before opening a PR.

            Keep commits small and focused (e.g. one task per PR in `PLAN.md` v1.0). Never force-push `main`!
            """

        let units = MarkdownRuleSplitter.splitDocument(doc)
        #expect(units.count == 6)

        guard units.count == 6 else { return }

        #expect(units[0].kind == .bullet)
        #expect(units[0].headingPath == ["Coding Standards", "Formatting"])
        #expect(units[0].lineRange == 7...8)
        #expect(
            units[0].normalizedText
                == "use 4 spaces for indentation in *.swift files. continuation line of the first bullet."
        )

        #expect(units[1].kind == .bullet)
        #expect(units[1].headingPath == ["Coding Standards", "Formatting"])
        #expect(units[1].lineRange == 9...9)
        #expect(units[1].normalizedText == "prefer swift testing over xctest.")

        #expect(units[2].kind == .numbered)
        #expect(units[2].headingPath == ["Coding Standards", "Workflow"])
        #expect(units[2].lineRange == 17...17)
        #expect(units[2].normalizedText == "write failing tests in tests/ first.")

        #expect(units[3].kind == .numbered)
        #expect(units[3].headingPath == ["Coding Standards", "Workflow"])
        #expect(units[3].lineRange == 18...18)

        #expect(units[4].kind == .paragraph)
        #expect(units[4].headingPath == ["Coding Standards", "Workflow"])
        #expect(units[4].lineRange == 20...20)
        #expect(
            units[4].normalizedText
                == "keep commits small and focused (e.g. one task per pr in plan.md v1.0)."
        )

        #expect(units[5].kind == .paragraph)
        #expect(units[5].headingPath == ["Coding Standards", "Workflow"])
        #expect(units[5].lineRange == 20...20)
        #expect(units[5].normalizedText == "never force-push main!")
    }

    @Test("Normalize strips markdown emphasis, checkboxes, blockquotes, links, and collapses whitespace")
    func normalizesMarkdownSyntax() {
        let normalized = MarkdownRuleSplitter.normalize(
            "> - [x]   **Always**   run   `Scripts/lint-writes.sh` & check _all_ [docs](https://example.com)!"
        )
        #expect(normalized == "always run scripts/lint-writes.sh & check all docs!")
    }
}
