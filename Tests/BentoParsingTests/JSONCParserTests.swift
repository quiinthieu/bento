import BentoCore
import BentoParsing
import BentoTestSupport
import Foundation
import Testing

@Suite("JSONCParser Tests")
struct JSONCParserTests {
    @Test("Parses JSONC with line comments, block comments, trailing commas, BOM, and exact scalar types")
    func parsesJSONCFeaturesAndScalarTypes() throws {
        let hostile = try FixtureHome(scenario: "hostile")
        let env = hostile.makeEnvironment()
        let data = try env.fileSystem.contents(
            at: hostile.url.appendingPathComponent("json/valid-jsonc-with-secrets.json")
        )

        let object = try JSONCParser.parseObject(data)
        #expect(object["enabled"] == .bool(true))
        #expect(object["retryCount"] == .int(3))
        #expect(
            object["endpoint"]
                == .string("https://api.example.com/v1/*not-a-comment*///still-url")
        )
        #expect(object["apiKey"] == .string(SecretRedactor.marker))

        if case .object(let servers) = object["mcpServers"],
            case .object(let github) = servers["github"],
            case .object(let envMap) = github["env"]
        {
            #expect(envMap["GITHUB_WORKSPACE_VAR"] == .string(SecretRedactor.marker))
            #expect(envMap["PLAIN_FLAG"] == .string(SecretRedactor.marker))
        } else {
            Issue.record("Expected nested mcpServers.github.env object")
        }
    }

    @Test("Handles UTF-8 BOM, unicode escapes, surrogate pairs, floats, negatives, and nulls")
    func parsesEscapesAndNumericEdgeCases() throws {
        let jsonWithBOM =
            "\u{FEFF}{\"flag\": false, \"zero\": 0, \"neg\": -42, \"pi\": 3.14, \"nilVal\": null, \"emoji\": \"\\uD83D\\uDE80\"}"
        let parsed = try JSONCParser.parseObject(jsonWithBOM)
        #expect(parsed["flag"] == .bool(false))
        #expect(parsed["zero"] == .int(0))
        #expect(parsed["neg"] == .int(-42))
        #expect(parsed["pi"] == .double(3.14))
        #expect(parsed["nilVal"] == .null)
        #expect(parsed["emoji"] == .string("🚀"))
    }

    @Test("Malformed hostile JSON files produce diagnostics without crashing")
    func handlesHostileMalformedJSON() throws {
        let hostile = try FixtureHome(scenario: "hostile")
        let env = hostile.makeEnvironment()

        for relative in ["json/invalid-syntax.json", "json/unclosed-comment.json"] {
            let url = hostile.url.appendingPathComponent(relative)
            let data = try env.fileSystem.contents(at: url)
            #expect(throws: BentoParsingError.self) {
                _ = try JSONCParser.parseObject(data)
            }
            let location = SourceLocation(path: url.path, realPath: url.path)
            let (settings, diagnostics) = JSONCParser.parseSettings(data, location: location)
            #expect(settings == nil)
            #expect(!diagnostics.isEmpty)
            #expect(diagnostics.first?.severity == .error)
        }
    }

    @Test("Rejects deeply nested adversarial JSON arrays exceeding maxDepth")
    func enforcesMaxNestingDepth() {
        let deep = String(repeating: "[", count: 200) + "1" + String(repeating: "]", count: 200)
        #expect(throws: BentoParsingError.self) {
            _ = try JSONCParser.parseValue(deep, maxDepth: 64)
        }
    }
}
