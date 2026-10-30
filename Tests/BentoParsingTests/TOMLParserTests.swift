import BentoCore
import BentoParsing
import BentoTestSupport
import Foundation
import Testing

@Suite("TOMLParser Tests")
struct TOMLParserTests {
    @Test("Parses Codex-style TOML with nested tables, arrays, scalars, and parse-time redaction")
    func parsesValidTOMLAndRedactsSecrets() throws {
        let hostile = try FixtureHome(scenario: "hostile")
        let env = hostile.makeEnvironment()
        let data = try env.fileSystem.contents(
            at: hostile.url.appendingPathComponent("toml/valid-toml-with-secrets.toml")
        )

        let tree = try TOMLParser.parseObject(data)
        #expect(tree["model"] == .string("gpt-5-codex"))
        #expect(tree["project_doc_max_bytes"] == .int(32768))
        #expect(tree["api_key"] == .string(SecretRedactor.marker))

        if case .object(let auth) = tree["auth"] {
            #expect(auth["refresh_token"] == .string(SecretRedactor.marker))
            #expect(auth["client_secret"] == .string(SecretRedactor.marker))
            #expect(auth["proxy_password"] == .string(SecretRedactor.marker))
        } else {
            Issue.record("Expected [auth] table")
        }

        if case .object(let servers) = tree["mcp_servers"],
            case .object(let github) = servers["github"],
            case .object(let remote) = servers["remote"]
        {
            let githubConfig = try #require(SecretRedactor.extractMCPServerConfig(from: github))
            #expect(
                githubConfig.transport
                    == .stdio(command: "npx", args: ["-y", "@modelcontextprotocol/server-github"])
            )
            #expect(githubConfig.envKeys == ["CUSTOM_UPSTREAM_CREDS"])
            #expect(!githubConfig.disabled)

            if case .object(let headers) = remote["http_headers"] {
                #expect(headers["Authorization"] == .string(SecretRedactor.marker))
                #expect(headers["X-Team-Context"] == .string(SecretRedactor.marker))
            } else {
                Issue.record("Expected [mcp_servers.remote.http_headers] table")
            }
        } else {
            Issue.record("Expected [mcp_servers] tables")
        }
    }

    @Test("Parses TOML dates, floats, booleans, and polyglot config.toml")
    func parsesTOMLDatesAndPolyglotFixture() throws {
        let toml = """
            enabled = false
            ratio = 1.25
            released_at = 2026-10-30T12:00:00Z
            local_day = 2026-10-30
            """
        let parsed = try TOMLParser.parseObject(toml)
        #expect(parsed["enabled"] == .bool(false))
        #expect(parsed["ratio"] == .double(1.25))
        if case .string(let ts) = parsed["released_at"] {
            #expect(ts.contains("2026-10-30"))
        } else {
            Issue.record("Expected date-time converted to string JSONValue")
        }

        let polyglot = try FixtureHome(scenario: "polyglot")
        let polyglotData = try polyglot.makeEnvironment().fileSystem.contents(
            at: polyglot.url.appendingPathComponent(".codex/config.toml")
        )
        let (settings, diagnostics) = TOMLParser.parseSettings(polyglotData)
        #expect(diagnostics.isEmpty)
        #expect(settings?.format == .toml)
        #expect(settings?.tree["model"] == .string("gpt-5-codex"))
    }

    @Test("Malformed hostile TOML files produce diagnostics without crashing")
    func handlesHostileMalformedTOML() throws {
        let hostile = try FixtureHome(scenario: "hostile")
        let env = hostile.makeEnvironment()

        for relative in ["toml/invalid-config.toml", "toml/duplicate-keys.toml"] {
            let url = hostile.url.appendingPathComponent(relative)
            let data = try env.fileSystem.contents(at: url)
            #expect(throws: BentoParsingError.self) {
                _ = try TOMLParser.parseObject(data)
            }
            let (settings, diagnostics) = TOMLParser.parseSettings(
                data,
                location: SourceLocation(path: url.path, realPath: url.path)
            )
            #expect(settings == nil)
            #expect(!diagnostics.isEmpty)
            #expect(diagnostics.first?.severity == .error)
        }
    }
}
