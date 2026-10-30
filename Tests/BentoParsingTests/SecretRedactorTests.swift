import BentoCore
import BentoParsing
import BentoTestSupport
import Foundation
import Testing

@Suite("SecretRedactor Tests")
struct SecretRedactorTests {
    static let fixtureSecrets: [String] = [
        "TEST_SYNTHETIC_SECRET_ALPHA_01",
        "TEST_SYNTHETIC_MCP_ENV_BRAVO_02",
        "TEST_SYNTHETIC_HEADER_CHARLIE_03",
        "TEST_SYNTHETIC_PASSWORD_DELTA_04",
        "TEST_SYNTHETIC_TOKEN_ECHO_05",
        "TEST_SYNTHETIC_APIKEY_FOXTROT_06",
        "TEST_SYNTHETIC_BEARER_GOLF_07",
        "TEST_SYNTHETIC_MCP_ENV_PLAIN_08"
    ]

    @Test("Key regex /(key|token|secret|password)/i and Authorization are detected")
    func sensitiveKeyMatching() {
        #expect(SecretRedactor.isSensitiveKey("apiKey"))
        #expect(SecretRedactor.isSensitiveKey("ANTHROPIC_API_KEY"))
        #expect(SecretRedactor.isSensitiveKey("access_token"))
        #expect(SecretRedactor.isSensitiveKey("refreshToken"))
        #expect(SecretRedactor.isSensitiveKey("client_secret"))
        #expect(SecretRedactor.isSensitiveKey("dbPassword"))
        #expect(SecretRedactor.isSensitiveKey("Authorization"))
        #expect(SecretRedactor.isSensitiveKey("authorization"))

        #expect(!SecretRedactor.isSensitiveKey("model"))
        #expect(!SecretRedactor.isSensitiveKey("command"))
        #expect(!SecretRedactor.isSensitiveKey("enabledMcpjsonServers"))
        #expect(!SecretRedactor.isSensitiveKey("project_doc_max_bytes"))
    }

    @Test("No secret values survive in payload_json across JSONC, TOML, Frontmatter, and MCPServerConfig")
    func noSecretsSurviveInPayloadJSON() throws {
        let hostile = try FixtureHome(scenario: "hostile")
        let env = hostile.makeEnvironment()

        let jsonData = try env.fileSystem.contents(
            at: hostile.url.appendingPathComponent("json/valid-jsonc-with-secrets.json")
        )
        let (jsonSettingsOpt, jsonDiags) = JSONCParser.parseSettings(jsonData)
        #expect(jsonDiags.isEmpty)
        let jsonSettings = try #require(jsonSettingsOpt)

        let tomlData = try env.fileSystem.contents(
            at: hostile.url.appendingPathComponent("toml/valid-toml-with-secrets.toml")
        )
        let (tomlSettingsOpt, tomlDiags) = TOMLParser.parseSettings(tomlData)
        #expect(tomlDiags.isEmpty)
        let tomlSettings = try #require(tomlSettingsOpt)

        let fmData = try env.fileSystem.contents(
            at: hostile.url.appendingPathComponent("markdown/secrets-frontmatter.md")
        )
        let fmDoc = try FrontmatterParser.parse(fmData)
        let fmDict = try #require(fmDoc.frontmatter)

        let dynamicGitHubToken = "ghp_" + String(repeating: "x", count: 36)
        let dynamicAnthropicKey = "sk-ant-" + String(repeating: "a", count: 28)
        let rawMCPObject: [String: JSONValue] = [
            "command": .string("npx"),
            "args": .array([
                .string("-y"),
                .string("@acme/mcp"),
                .string("--header"),
                .string("Authorization: Bearer " + dynamicAnthropicKey),
                .string(dynamicGitHubToken)
            ]),
            "env": .object([
                "GITHUB_PERSONAL_ACCESS_TOKEN": .string(dynamicGitHubToken),
                "PLAIN_UPSTREAM_VALUE": .string("TEST_SYNTHETIC_MCP_ENV_PLAIN_08")
            ]),
            "disabled": .bool(false)
        ]
        let mcpConfig = try #require(SecretRedactor.extractMCPServerConfig(from: rawMCPObject))
        #expect(mcpConfig.envKeys == ["GITHUB_PERSONAL_ACCESS_TOKEN", "PLAIN_UPSTREAM_VALUE"])

        let payloads: [ArtifactPayload] = [
            .settings(jsonSettings),
            .settings(tomlSettings),
            .skill(
                SkillDoc(
                    name: "deploy-helper",
                    description: "Deployment automation skill",
                    frontmatter: fmDict,
                    body: fmDoc.body
                )
            ),
            .mcpServer(mcpConfig)
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for payload in payloads {
            let redactedPayload = SecretRedactor.redact(payload)
            let payloadJSONBytes = try encoder.encode(redactedPayload)
            let payloadJSON = try #require(String(data: payloadJSONBytes, encoding: .utf8))

            for secret in Self.fixtureSecrets {
                #expect(
                    !payloadJSON.contains(secret),
                    "Secret '\(secret)' leaked into payload_json: \(payloadJSON)"
                )
            }
            #expect(!payloadJSON.contains(dynamicGitHubToken))
            #expect(!payloadJSON.contains(dynamicAnthropicKey))
        }

        // Non-secret structural fields and env key names remain intact.
        #expect(
            jsonSettings.tree["endpoint"]
                == .string("https://api.example.com/v1/*not-a-comment*///still-url")
        )
        #expect(jsonSettings.tree["apiKey"] == .string(SecretRedactor.marker))
        #expect(tomlSettings.tree["model"] == .string("gpt-5-codex"))
        #expect(tomlSettings.tree["api_key"] == .string(SecretRedactor.marker))
    }

    @Test("Redacts URL userinfo, sensitive query params, and nested arrays/objects under secret keys")
    func redactsInlineAndNestedSecrets() {
        let raw: [String: JSONValue] = [
            "mcpUrl": .string("https://admin:mySuperPass123@mcp.internal.local/sse?token=xyz987&mode=fast"),
            "apiKeys": .array([.string("first-raw-val"), .string("second-raw-val")]),
            "headers": .object([
                "X-Org": .string("org-raw-header-value")
            ]),
            "safeUrl": .string("https://mcp.internal.local/sse?mode=fast")
        ]

        let redacted = SecretRedactor.redact(raw)
        let encoded = try? JSONEncoder().encode(redacted)
        let jsonString = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? ""

        #expect(!jsonString.contains("mySuperPass123"))
        #expect(!jsonString.contains("xyz987"))
        #expect(!jsonString.contains("first-raw-val"))
        #expect(!jsonString.contains("second-raw-val"))
        #expect(!jsonString.contains("org-raw-header-value"))
        #expect(redacted["safeUrl"] == .string("https://mcp.internal.local/sse?mode=fast"))
        #expect(redacted["headers"] == .object(["X-Org": .string(SecretRedactor.marker)]))
    }
}
