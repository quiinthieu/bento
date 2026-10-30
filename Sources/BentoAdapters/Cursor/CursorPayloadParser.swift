import BentoCore
import BentoParsing
import Foundation

/// Pure payload and structured-entry parsers for Cursor configuration files.
enum CursorPayloadParser {
    /// Parses `~/.cursor/mcp.json` or `<repo>/.cursor/mcp.json`.
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
                agent: .cursor,
                kind: .mcpServer,
                scope: scope,
                path: identityPath
            )
            return [
                Artifact(
                    id: errID,
                    agent: .cursor,
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
                agent: .cursor,
                kind: .mcpServer,
                scope: scope,
                path: identityPath,
                keyPath: keyPath
            )

            var itemDiagnostics: [Diagnostic] = []
            let rawType = nonEmptyString(serverDict["type"])?.lowercased()
            let url = nonEmptyString(serverDict["url"]) ?? nonEmptyString(serverDict["serverUrl"])
            let command = nonEmptyString(serverDict["command"])

            let transport: MCPServerConfig.Transport
            if rawType == "sse", let url {
                transport = .sse(url: url)
            } else if let url, command == nil {
                if rawType == "http" {
                    transport = .http(url: url)
                } else if url.lowercased().contains("/sse") {
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
                        message: "Cursor MCP server '\(serverName)' is missing 'command' or 'url'",
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
                    agent: .cursor,
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

    /// Parses a Cursor `.mdc` (or `.cursor/rules/**/*.md`) rule file using `MDCParser`.
    static func parseMDCRuleFile(
        at fileURL: URL,
        scope: Scope,
        displayName: String,
        in env: AgentEnvironment
    ) -> Artifact {
        let location = AdapterPathNormalizer.sourceLocation(for: fileURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        let id = ArtifactID(
            agent: .cursor,
            kind: .rules,
            scope: scope,
            path: identityPath
        )

        guard let rawData = try? env.fileSystem.contents(at: fileURL) else {
            let diag = Diagnostic(
                code: "rules.readFailed",
                severity: .error,
                message: "Cannot read Cursor rule file '\(fileURL.lastPathComponent)'",
                location: location
            )
            return Artifact(
                id: id,
                agent: .cursor,
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
        do {
            let mdc = try MDCParser.parse(rawData, location: location, redactSecrets: true)
            return Artifact(
                id: id,
                agent: .cursor,
                kind: .rules,
                scope: scope,
                name: displayName,
                location: location,
                contentHash: contentHash,
                enabled: true,
                loadMode: mdc.effectiveLoadMode,
                payload: .rules(mdc.rulesDoc),
                diagnostics: mdc.diagnostics
            )
        } catch {
            let diag = Diagnostic(
                code: "rules.invalidUTF8",
                severity: .error,
                message: "Cursor rule file '\(fileURL.lastPathComponent)' is not valid UTF-8",
                location: location
            )
            return Artifact(
                id: id,
                agent: .cursor,
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
    }

    /// Parses plain Markdown rule files (`.cursorrules`, `AGENTS.md`).
    static func parsePlainRulesFile(
        at fileURL: URL,
        scope: Scope,
        name: String,
        loadMode: LoadMode,
        in env: AgentEnvironment
    ) -> Artifact {
        let location = AdapterPathNormalizer.sourceLocation(for: fileURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        let id = ArtifactID(
            agent: .cursor,
            kind: .rules,
            scope: scope,
            path: identityPath
        )

        guard let rawData = try? env.fileSystem.contents(at: fileURL),
            let text = String(data: rawData, encoding: .utf8)
        else {
            let diag = Diagnostic(
                code: "rules.readFailed",
                severity: .error,
                message: "Cannot read Cursor instructions file '\(fileURL.lastPathComponent)'",
                location: location
            )
            return Artifact(
                id: id,
                agent: .cursor,
                kind: .rules,
                scope: scope,
                name: name,
                location: location,
                contentHash: ContentHasher.sha256Hex(Data()),
                enabled: false,
                loadMode: .never,
                payload: .other,
                diagnostics: [diag]
            )
        }

        let doc = RulesDoc(
            content: text,
            imports: [],
            frontmatter: nil,
            byteCount: rawData.count,
            characterCount: text.count,
            wasTruncated: false
        )

        return Artifact(
            id: id,
            agent: .cursor,
            kind: .rules,
            scope: scope,
            name: name,
            location: location,
            contentHash: hashData(rawData),
            enabled: true,
            loadMode: loadMode,
            payload: .rules(doc)
        )
    }

    static func parseSkillDirectory(
        at skillDir: URL,
        scope: Scope,
        in env: AgentEnvironment
    ) -> Artifact? {
        let fs = env.fileSystem
        let skillFile = CursorPathCatalog.skillMarkdownFile(in: skillDir)
        guard AdapterPathNormalizer.isEffectiveFile(skillFile, fileSystem: fs),
            let rawData = try? fs.contents(at: skillFile),
            let text = String(data: rawData, encoding: .utf8)
        else {
            return nil
        }

        let location = AdapterPathNormalizer.sourceLocation(for: skillFile, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: skillFile, in: env)
        let id = ArtifactID(
            agent: .cursor,
            kind: .skill,
            scope: scope,
            path: identityPath
        )

        let parsed = FrontmatterParser.parse(text, location: location, redactSecrets: true)
        let frontmatter = parsed.frontmatter ?? [:]
        let skillName = nonEmptyString(frontmatter["name"]) ?? skillDir.lastPathComponent
        let description = nonEmptyString(frontmatter["description"])

        let supportingFiles = AdapterPathNormalizer.collectFilesRecursively(
            under: skillDir,
            fileSystem: fs
        ) { candidate in
            candidate.standardizedFileURL.path != skillFile.standardizedFileURL.path
                && candidate.lastPathComponent != ".DS_Store"
        }.compactMap { url in
            AdapterPathNormalizer.relativePath(of: url, from: skillDir, fileSystem: fs)
        }

        let doc = SkillDoc(
            name: skillName,
            description: description,
            frontmatter: frontmatter,
            body: parsed.body,
            supportingFiles: supportingFiles
        )

        return Artifact(
            id: id,
            agent: .cursor,
            kind: .skill,
            scope: scope,
            name: skillName,
            location: location,
            contentHash: hashData(rawData),
            enabled: true,
            loadMode: .frontmatterOnly,
            payload: .skill(doc),
            diagnostics: parsed.diagnostics
        )
    }

    static func parseSubagentFile(
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
            agent: .cursor,
            kind: .subagent,
            scope: scope,
            path: identityPath
        )
        let parsed = FrontmatterParser.parse(text, location: location, redactSecrets: true)
        let frontmatter = parsed.frontmatter ?? [:]

        let name = nonEmptyString(frontmatter["name"]) ?? fileURL.deletingPathExtension().lastPathComponent
        let description = nonEmptyString(frontmatter["description"])
        let model = nonEmptyString(frontmatter["model"])
        let tools = stringArray(frontmatter["tools"])

        let doc = SubagentDoc(
            name: name,
            description: description,
            model: model,
            tools: tools,
            frontmatter: frontmatter,
            body: parsed.body
        )

        return Artifact(
            id: id,
            agent: .cursor,
            kind: .subagent,
            scope: scope,
            name: name,
            location: location,
            contentHash: hashData(rawData),
            enabled: true,
            loadMode: .frontmatterOnly,
            payload: .subagent(doc),
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
            agent: .cursor,
            kind: .ignoreFile,
            scope: scope,
            path: identityPath
        )

        return Artifact(
            id: id,
            agent: .cursor,
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
}
