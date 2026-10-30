import BentoCore
import BentoParsing
import Foundation

/// Pure payload and structured-entry parsers for Windsurf Cascade configuration files.
enum WindsurfPayloadParser {
    /// Parses `~/.codeium/windsurf/mcp_config.json`.
    static func parseMCPFile(
        at fileURL: URL,
        scope: Scope,
        in env: AgentEnvironment
    ) -> [Artifact] {
        let baseLocation = AdapterPathNormalizer.sourceLocation(for: fileURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        guard let rawData = try? env.fileSystem.contents(at: fileURL) else {
            return []
        }

        let contentHash = hashData(rawData)
        let (settingsDoc, diagnostics) = JSONCParser.parseSettings(rawData, location: baseLocation)

        guard let tree = settingsDoc?.tree else {
            let errID = ArtifactID(
                agent: .windsurf,
                kind: .mcpServer,
                scope: scope,
                path: identityPath
            )
            return [
                Artifact(
                    id: errID,
                    agent: .windsurf,
                    kind: .mcpServer,
                    scope: scope,
                    name: fileURL.lastPathComponent,
                    location: baseLocation,
                    contentHash: contentHash,
                    enabled: false,
                    loadMode: .never,
                    payload: .other,
                    diagnostics: diagnostics
                )
            ]
        }

        guard case .object(let serversMap) = tree["mcpServers"] else {
            return []
        }

        var results: [Artifact] = []
        for serverName in serversMap.keys.sorted() {
            guard case .object(let serverDict) = serversMap[serverName] else { continue }
            let keyPath = ["mcpServers", serverName]
            let location = AdapterPathNormalizer.sourceLocation(for: fileURL, keyPath: keyPath, in: env)
            let id = ArtifactID(
                agent: .windsurf,
                kind: .mcpServer,
                scope: scope,
                path: identityPath,
                keyPath: keyPath
            )

            var itemDiagnostics: [Diagnostic] = []
            let rawType = nonEmptyString(serverDict["type"])?.lowercased()
            let url =
                nonEmptyString(serverDict["serverUrl"])
                ?? nonEmptyString(serverDict["url"])
                ?? nonEmptyString(serverDict["httpUrl"])
            let command = nonEmptyString(serverDict["command"])

            let transport: MCPServerConfig.Transport
            if rawType == "sse", let url {
                transport = .sse(url: url)
            } else if let url, command == nil {
                if url.lowercased().hasSuffix("/sse") && rawType != "http" {
                    transport = .sse(url: url)
                } else {
                    transport = .http(url: url)
                }
            } else if let command {
                let args = stringArray(serverDict["args"]) ?? []
                transport = .stdio(command: command, args: args)
            } else {
                transport = .stdio(command: "", args: [])
                itemDiagnostics.append(
                    Diagnostic(
                        code: "mcp.missingTransport",
                        severity: .warning,
                        message: "Windsurf MCP server '\(serverName)' is missing 'command' or 'serverUrl'",
                        location: location
                    )
                )
            }

            var envKeys: [String] = []
            if case .object(let envObj) = serverDict["env"] {
                envKeys = envObj.keys.sorted()
            }

            let isDisabled =
                (boolValue(serverDict["disabled"]) == true) || (boolValue(serverDict["enabled"]) == false)
            let config = MCPServerConfig(
                transport: transport,
                envKeys: envKeys,
                disabled: isDisabled,
                allowedTools: stringArray(serverDict["allowedTools"]),
                disabledTools: stringArray(serverDict["disabledTools"])
            )

            results.append(
                Artifact(
                    id: id,
                    agent: .windsurf,
                    kind: .mcpServer,
                    scope: scope,
                    name: serverName,
                    location: location,
                    contentHash: contentHash,
                    enabled: !isDisabled,
                    loadMode: isDisabled ? .never : .always,
                    payload: .mcpServer(config),
                    diagnostics: itemDiagnostics
                )
            )
        }

        return results
    }

    /// Parses a Windsurf rule file (`global_rules.md`, `.windsurf/rules/**/*.md`, `.windsurfrules`, `AGENTS.md`, enterprise rules)
    /// enforcing the verified 6,000 / 12,000 character cap and YAML frontmatter `trigger` modes.
    static func parseRuleFile(
        at fileURL: URL,
        scope: Scope,
        displayName: String,
        parseFrontmatterTrigger: Bool,
        defaultLoadMode: LoadMode = .always,
        maxCharacters: Int,
        in env: AgentEnvironment
    ) -> Artifact {
        let location = AdapterPathNormalizer.sourceLocation(for: fileURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        let id = ArtifactID(
            agent: .windsurf,
            kind: .rules,
            scope: scope,
            path: identityPath
        )

        guard let rawData = try? env.fileSystem.contents(at: fileURL) else {
            let diag = Diagnostic(
                code: "rules.readFailed",
                severity: .error,
                message: "Cannot read Windsurf rule file '\(fileURL.lastPathComponent)'",
                location: location
            )
            return Artifact(
                id: id,
                agent: .windsurf,
                kind: .rules,
                scope: scope,
                name: displayName,
                location: location,
                contentHash: ContentHasher.sha256Hex(Data()),
                enabled: false,
                loadMode: .never,
                payload: .other,
                diagnostics: [diag]
            )
        }

        let contentHash = hashData(rawData)
        guard let text = String(data: rawData, encoding: .utf8) else {
            let diag = Diagnostic(
                code: "rules.invalidUTF8",
                severity: .error,
                message: "Windsurf rule file '\(fileURL.lastPathComponent)' is not valid UTF-8",
                location: location
            )
            return Artifact(
                id: id,
                agent: .windsurf,
                kind: .rules,
                scope: scope,
                name: displayName,
                location: location,
                contentHash: contentHash,
                enabled: false,
                loadMode: .never,
                payload: .other,
                diagnostics: [diag]
            )
        }

        var diagnostics: [Diagnostic] = []
        let bodyText: String
        let frontmatter: [String: JSONValue]?
        let loadMode: LoadMode

        if parseFrontmatterTrigger {
            let parsed = FrontmatterParser.parse(text, location: location, redactSecrets: true)
            diagnostics.append(contentsOf: parsed.diagnostics)
            frontmatter = parsed.frontmatter
            bodyText = parsed.body

            let trigger = nonEmptyString(frontmatter?["trigger"])?.lowercased()
            let globs = extractGlobs(from: frontmatter?["globs"])

            switch trigger {
            case "always_on":
                loadMode = .always
            case "glob":
                if !globs.isEmpty {
                    loadMode = .conditional(globs: globs)
                } else {
                    loadMode = .onInvoke
                    diagnostics.append(
                        Diagnostic(
                            code: "rules.missingGlobs",
                            severity: .warning,
                            message: "Windsurf rule '\(displayName)' specifies 'trigger: glob' without 'globs'",
                            location: location
                        )
                    )
                }
            case "model_decision", "manual":
                loadMode = .onInvoke
            case nil:
                loadMode = !globs.isEmpty ? .conditional(globs: globs) : defaultLoadMode
            case .some(let unknownTrigger):
                loadMode = !globs.isEmpty ? .conditional(globs: globs) : defaultLoadMode
                diagnostics.append(
                    Diagnostic(
                        code: "rules.unknownTrigger",
                        severity: .warning,
                        message: "Windsurf rule '\(displayName)' uses unrecognized trigger '\(unknownTrigger)'",
                        location: location
                    )
                )
            }
        } else {
            frontmatter = nil
            bodyText = text
            loadMode = defaultLoadMode
        }

        let charCount = text.count
        let wasTruncated = charCount > maxCharacters
        if wasTruncated {
            diagnostics.append(
                Diagnostic(
                    code: "rules.sizeLimitExceeded",
                    severity: .warning,
                    message:
                        "Windsurf rule file '\(displayName)' exceeds \(maxCharacters)-character limit (\(charCount) characters)",
                    location: location
                )
            )
        }

        let doc = RulesDoc(
            content: bodyText,
            imports: [],
            frontmatter: frontmatter,
            byteCount: rawData.count,
            characterCount: charCount,
            wasTruncated: wasTruncated
        )

        return Artifact(
            id: id,
            agent: .windsurf,
            kind: .rules,
            scope: scope,
            name: displayName,
            location: location,
            contentHash: contentHash,
            enabled: true,
            loadMode: loadMode,
            payload: .rules(doc),
            diagnostics: diagnostics
        )
    }

    static func parseWorkflowFile(
        at fileURL: URL,
        scope: Scope,
        in env: AgentEnvironment
    ) -> Artifact? {
        guard let rawData = try? env.fileSystem.contents(at: fileURL),
            let text = String(data: rawData, encoding: .utf8)
        else {
            return nil
        }

        let location = AdapterPathNormalizer.sourceLocation(for: fileURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        let id = ArtifactID(
            agent: .windsurf,
            kind: .command,
            scope: scope,
            path: identityPath
        )

        let parsed = FrontmatterParser.parse(text, location: location, redactSecrets: true)
        let frontmatter = parsed.frontmatter ?? [:]
        let name = nonEmptyString(frontmatter["name"]) ?? fileURL.deletingPathExtension().lastPathComponent
        let description = nonEmptyString(frontmatter["description"])

        let doc = CommandDoc(
            name: name,
            description: description,
            argumentHint: nil,
            body: parsed.body
        )

        return Artifact(
            id: id,
            agent: .windsurf,
            kind: .command,
            scope: scope,
            name: name,
            location: location,
            contentHash: hashData(rawData),
            enabled: true,
            loadMode: .onInvoke,
            payload: .command(doc),
            diagnostics: parsed.diagnostics
        )
    }

    static func parseIgnoreFile(
        at fileURL: URL,
        scope: Scope,
        in env: AgentEnvironment
    ) -> Artifact? {
        guard let rawData = try? env.fileSystem.contents(at: fileURL) else {
            return nil
        }
        let location = AdapterPathNormalizer.sourceLocation(for: fileURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        let id = ArtifactID(
            agent: .windsurf,
            kind: .ignoreFile,
            scope: scope,
            path: identityPath
        )

        return Artifact(
            id: id,
            agent: .windsurf,
            kind: .ignoreFile,
            scope: scope,
            name: fileURL.lastPathComponent,
            location: location,
            contentHash: hashData(rawData),
            enabled: true,
            loadMode: .never,
            payload: .other
        )
    }

    // MARK: - Helpers

    private static func hashData(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            return ContentHasher.sha256NormalizedText(text)
        }
        return ContentHasher.sha256Hex(data)
    }

    private static func nonEmptyString(_ value: JSONValue?) -> String? {
        guard case .string(let raw) = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func boolValue(_ value: JSONValue?) -> Bool? {
        guard case .bool(let flag) = value else { return nil }
        return flag
    }

    private static func stringArray(_ value: JSONValue?) -> [String]? {
        guard case .array(let arr) = value else { return nil }
        let items = arr.compactMap { nonEmptyString($0) }
        return items.isEmpty ? nil : items
    }

    private static func extractGlobs(from value: JSONValue?) -> [String] {
        guard let value else { return [] }
        switch value {
        case .array(let elements):
            return elements.compactMap { item -> String? in
                guard let str = nonEmptyString(item) else { return nil }
                return cleanGlobToken(str)
            }
        case .string(let csv):
            return
                csv
                .split(separator: ",")
                .compactMap { cleanGlobToken(String($0)) }
        default:
            return []
        }
    }

    private static func cleanGlobToken(_ token: String) -> String? {
        var trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
            || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'"))
        {
            if trimmed.count >= 2 {
                trimmed.removeFirst()
                trimmed.removeLast()
            }
        }
        let cleaned = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
