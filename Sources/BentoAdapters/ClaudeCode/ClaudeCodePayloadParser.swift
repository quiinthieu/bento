import BentoCore
import BentoParsing
import Foundation

/// Pure payload and structured-entry parsers for Claude Code configuration files.
enum ClaudeCodePayloadParser {
    /// Parses a JSON/JSONC settings file into a `.settings` artifact and any embedded `.hook` artifacts.
    static func parseSettingsAndHooks(
        at fileURL: URL,
        scope: Scope,
        enabled: Bool = true,
        in env: AgentEnvironment
    ) -> (settingsArtifact: Artifact, hookArtifacts: [Artifact], parsedTree: [String: JSONValue]?) {
        let location = AdapterPathNormalizer.sourceLocation(for: fileURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        let artifactID = ArtifactID(
            agent: .claudeCode,
            kind: .settings,
            scope: scope,
            path: identityPath
        )

        let rawData: Data
        do {
            rawData = try env.fileSystem.contents(at: fileURL)
        } catch {
            let diag = Diagnostic(
                code: "settings.readFailed",
                severity: .error,
                message: "Cannot read settings file '\(fileURL.lastPathComponent)'",
                location: location
            )
            let fallback = Artifact(
                id: artifactID,
                agent: .claudeCode,
                kind: .settings,
                scope: scope,
                name: fileURL.lastPathComponent,
                location: location,
                contentHash: ContentHasher.sha256Hex(Data()),
                enabled: false,
                loadMode: .never,
                payload: .other,
                diagnostics: [diag]
            )
            return (fallback, [], nil)
        }

        let contentHash = hashData(rawData)
        let (settingsDoc, diagnostics) = JSONCParser.parseSettings(rawData, location: location)

        guard let settingsDoc else {
            let malformed = Artifact(
                id: artifactID,
                agent: .claudeCode,
                kind: .settings,
                scope: scope,
                name: fileURL.lastPathComponent,
                location: location,
                contentHash: contentHash,
                enabled: false,
                loadMode: .never,
                payload: .other,
                diagnostics: diagnostics
            )
            return (malformed, [], nil)
        }

        let settingsArtifact = Artifact(
            id: artifactID,
            agent: .claudeCode,
            kind: .settings,
            scope: scope,
            name: fileURL.lastPathComponent,
            location: location,
            contentHash: contentHash,
            enabled: enabled,
            loadMode: .never,
            payload: .settings(settingsDoc),
            diagnostics: diagnostics
        )

        let hooks = extractHooks(
            from: settingsDoc.tree,
            fileURL: fileURL,
            scope: scope,
            enabled: enabled,
            contentHash: contentHash,
            in: env
        )

        return (settingsArtifact, hooks, settingsDoc.tree)
    }

    /// Parses hooks from a standalone plugin `hooks.json` file or settings dictionary.
    static func parseStandaloneHooksFile(
        at fileURL: URL,
        scope: Scope,
        enabled: Bool,
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
                agent: .claudeCode,
                kind: .hook,
                scope: scope,
                path: identityPath
            )
            return [
                Artifact(
                    id: errID,
                    agent: .claudeCode,
                    kind: .hook,
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

        return extractHooks(
            from: tree,
            fileURL: fileURL,
            scope: scope,
            enabled: enabled,
            contentHash: contentHash,
            in: env
        )
    }

    /// Extracts `.hook` artifacts from a parsed JSON tree containing `"hooks"` (or top-level event map).
    static func extractHooks(
        from tree: [String: JSONValue],
        fileURL: URL,
        scope: Scope,
        enabled: Bool,
        contentHash: String,
        in env: AgentEnvironment
    ) -> [Artifact] {
        let hooksMap: [String: JSONValue]
        let rootPrefix: [String]
        if case .object(let nested) = tree["hooks"] {
            hooksMap = nested
            rootPrefix = ["hooks"]
        } else {
            return []
        }

        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        var results: [Artifact] = []

        for eventName in hooksMap.keys.sorted() {
            guard case .array(let groups) = hooksMap[eventName] else { continue }
            for (groupIndex, groupValue) in groups.enumerated() {
                guard case .object(let groupDict) = groupValue else { continue }
                let matcher = stringValue(groupDict["matcher"])

                if case .array(let innerHooks) = groupDict["hooks"] {
                    for (hookIndex, innerValue) in innerHooks.enumerated() {
                        guard case .object(let hookDict) = innerValue,
                            let command = stringValue(hookDict["command"]),
                            !command.isEmpty
                        else {
                            continue
                        }
                        let timeout = intValue(hookDict["timeout"])
                        let keyPath = rootPrefix + [eventName, "\(groupIndex)", "hooks", "\(hookIndex)"]
                        let displayName =
                            if let matcher, !matcher.isEmpty {
                                "\(eventName) (\(matcher))"
                            } else {
                                eventName
                            }
                        let location = AdapterPathNormalizer.sourceLocation(
                            for: fileURL,
                            keyPath: keyPath,
                            in: env
                        )
                        let id = ArtifactID(
                            agent: .claudeCode,
                            kind: .hook,
                            scope: scope,
                            path: identityPath,
                            keyPath: keyPath
                        )
                        let config = HookConfig(
                            event: eventName,
                            matcher: matcher,
                            command: command,
                            timeoutSeconds: timeout
                        )
                        results.append(
                            Artifact(
                                id: id,
                                agent: .claudeCode,
                                kind: .hook,
                                scope: scope,
                                name: displayName,
                                location: location,
                                contentHash: contentHash,
                                enabled: enabled,
                                loadMode: enabled ? .onInvoke : .never,
                                payload: .hook(config)
                            )
                        )
                    }
                } else if let directCommand = stringValue(groupDict["command"]), !directCommand.isEmpty {
                    let timeout = intValue(groupDict["timeout"])
                    let keyPath = rootPrefix + [eventName, "\(groupIndex)"]
                    let displayName =
                        if let matcher, !matcher.isEmpty {
                            "\(eventName) (\(matcher))"
                        } else {
                            eventName
                        }
                    let location = AdapterPathNormalizer.sourceLocation(
                        for: fileURL,
                        keyPath: keyPath,
                        in: env
                    )
                    let id = ArtifactID(
                        agent: .claudeCode,
                        kind: .hook,
                        scope: scope,
                        path: identityPath,
                        keyPath: keyPath
                    )
                    let config = HookConfig(
                        event: eventName,
                        matcher: matcher,
                        command: directCommand,
                        timeoutSeconds: timeout
                    )
                    results.append(
                        Artifact(
                            id: id,
                            agent: .claudeCode,
                            kind: .hook,
                            scope: scope,
                            name: displayName,
                            location: location,
                            contentHash: contentHash,
                            enabled: enabled,
                            loadMode: enabled ? .onInvoke : .never,
                            payload: .hook(config)
                        )
                    )
                }
            }
        }

        return results
    }

    /// Parses MCP servers from a dedicated MCP JSON file (`managed-mcp.json`, `<repo>/.mcp.json`, or plugin MCP file).
    static func parseMCPFile(
        at fileURL: URL,
        scope: Scope,
        parentEnabled: Bool = true,
        in env: AgentEnvironment
    ) -> [Artifact] {
        let baseLocation = AdapterPathNormalizer.sourceLocation(for: fileURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)

        guard let rawData = try? env.fileSystem.contents(at: fileURL) else {
            return []
        }

        let contentHash = hashData(rawData)
        // Parse without value redaction only to extract env key names? No: SecretRedactor preserves all keys
        // and only redacts values! MCPServerConfig never stores values, and URLs/commands are preserved unless
        // containing inline tokens. Using redactSecrets: true guarantees no secret ever enters memory unredacted!
        let (settingsDoc, diagnostics) = JSONCParser.parseSettings(rawData, location: baseLocation)

        guard let tree = settingsDoc?.tree else {
            let errID = ArtifactID(
                agent: .claudeCode,
                kind: .mcpServer,
                scope: scope,
                path: identityPath
            )
            return [
                Artifact(
                    id: errID,
                    agent: .claudeCode,
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

        if case .object(let serversMap) = tree["mcpServers"] {
            return parseMCPServersDictionary(
                serversMap,
                keyPrefix: ["mcpServers"],
                fileURL: fileURL,
                scope: scope,
                parentEnabled: parentEnabled,
                contentHash: contentHash,
                in: env
            )
        }

        // Tolerate flat server map in .mcp.json where top-level keys map directly to server objects.
        let looksLikeFlatServerMap =
            !tree.isEmpty
            && tree.values.allSatisfy {
                if case .object(let obj) = $0 {
                    return obj["command"] != nil || obj["url"] != nil
                }
                return false
            }
        if looksLikeFlatServerMap {
            return parseMCPServersDictionary(
                tree,
                keyPrefix: [],
                fileURL: fileURL,
                scope: scope,
                parentEnabled: parentEnabled,
                contentHash: contentHash,
                in: env
            )
        }

        return []
    }

    /// Parses a dictionary of `<serverName>: { command/args/url/type/env/disabled }` entries into `.mcpServer` artifacts.
    static func parseMCPServersDictionary(
        _ serversMap: [String: JSONValue],
        keyPrefix: [String],
        fileURL: URL,
        scope: Scope,
        parentEnabled: Bool = true,
        contentHash: String,
        in env: AgentEnvironment
    ) -> [Artifact] {
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        var artifacts: [Artifact] = []

        for serverName in serversMap.keys.sorted() {
            let keyPath = keyPrefix + [serverName]
            let location = AdapterPathNormalizer.sourceLocation(for: fileURL, keyPath: keyPath, in: env)
            let id = ArtifactID(
                agent: .claudeCode,
                kind: .mcpServer,
                scope: scope,
                path: identityPath,
                keyPath: keyPath
            )

            guard case .object(let entry) = serversMap[serverName] else {
                let diag = Diagnostic(
                    code: "mcp.invalidEntry",
                    severity: .warning,
                    message: "MCP server '\(serverName)' must be a JSON object",
                    location: location
                )
                artifacts.append(
                    Artifact(
                        id: id,
                        agent: .claudeCode,
                        kind: .mcpServer,
                        scope: scope,
                        name: serverName,
                        location: location,
                        contentHash: contentHash,
                        enabled: false,
                        loadMode: .never,
                        payload: .other,
                        diagnostics: [diag]
                    )
                )
                continue
            }

            let isDisabled = boolValue(entry["disabled"]) == true || !parentEnabled
            let envKeys: [String] =
                if case .object(let envObj) = entry["env"] {
                    envObj.keys.sorted()
                } else {
                    []
                }
            let allowedTools = stringArray(entry["allowedTools"])
            let disabledTools = stringArray(entry["disabledTools"])
            let transportType = stringValue(entry["type"])?.lowercased()

            let transport: MCPServerConfig.Transport?
            if transportType == "sse", let url = stringValue(entry["url"]), !url.isEmpty {
                transport = .sse(url: url)
            } else if transportType == "http", let url = stringValue(entry["url"]), !url.isEmpty {
                transport = .http(url: url)
            } else if let command = stringValue(entry["command"]), !command.isEmpty {
                let args = stringArray(entry["args"]) ?? []
                transport = .stdio(command: command, args: args)
            } else if let url = stringValue(entry["url"]), !url.isEmpty {
                transport = .http(url: url)
            } else {
                transport = nil
            }

            guard let transport else {
                let diag = Diagnostic(
                    code: "mcp.missingTransport",
                    severity: .warning,
                    message: "MCP server '\(serverName)' is missing 'command' or 'url'",
                    location: location
                )
                artifacts.append(
                    Artifact(
                        id: id,
                        agent: .claudeCode,
                        kind: .mcpServer,
                        scope: scope,
                        name: serverName,
                        location: location,
                        contentHash: contentHash,
                        enabled: false,
                        loadMode: .never,
                        payload: .other,
                        diagnostics: [diag]
                    )
                )
                continue
            }

            let config = MCPServerConfig(
                transport: transport,
                envKeys: envKeys,
                disabled: isDisabled,
                allowedTools: allowedTools,
                disabledTools: disabledTools
            )
            artifacts.append(
                Artifact(
                    id: id,
                    agent: .claudeCode,
                    kind: .mcpServer,
                    scope: scope,
                    name: serverName,
                    location: location,
                    contentHash: contentHash,
                    enabled: !isDisabled,
                    loadMode: isDisabled ? .never : .always,
                    payload: .mcpServer(config)
                )
            )
        }

        return artifacts
    }

    /// Parses a modular `.md` rule file (e.g. under `.claude/rules/`), supporting optional `paths:` YAML frontmatter.
    static func parseModularRuleFile(
        at fileURL: URL,
        relativeName: String,
        scope: Scope,
        in env: AgentEnvironment
    ) -> Artifact? {
        guard let rawData = try? env.fileSystem.contents(at: fileURL) else {
            return nil
        }

        let location = AdapterPathNormalizer.sourceLocation(for: fileURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        let id = ArtifactID(
            agent: .claudeCode,
            kind: .rules,
            scope: scope,
            path: identityPath
        )

        guard let rawText = String(data: rawData, encoding: .utf8) else {
            let diag = Diagnostic(
                code: "rules.invalidUTF8",
                severity: .warning,
                message: "Rule file '\(relativeName)' is not valid UTF-8",
                location: location
            )
            return Artifact(
                id: id,
                agent: .claudeCode,
                kind: .rules,
                scope: scope,
                name: relativeName,
                location: location,
                contentHash: ContentHasher.sha256Hex(rawData),
                enabled: false,
                loadMode: .never,
                payload: .other,
                diagnostics: [diag]
            )
        }

        let frontDoc = FrontmatterParser.parse(rawText, location: location)
        let globs = extractPathGlobs(from: frontDoc.frontmatter)
        let loadMode: LoadMode = globs.isEmpty ? .always : .conditional(globs: globs)

        let importRes = ImportResolver(syntax: .claudeCode).resolve(
            markdown: frontDoc.body,
            sourceURL: fileURL,
            homeURL: env.home,
            fileSystem: env.fileSystem
        )

        let rulesDoc = RulesDoc(
            content: frontDoc.body,
            imports: importRes.directImports,
            frontmatter: frontDoc.frontmatter,
            byteCount: rawData.count,
            characterCount: rawText.count,
            wasTruncated: false
        )

        return Artifact(
            id: id,
            agent: .claudeCode,
            kind: .rules,
            scope: scope,
            name: relativeName,
            location: location,
            contentHash: ContentHasher.sha256NormalizedText(rawText),
            enabled: true,
            loadMode: loadMode,
            payload: .rules(rulesDoc),
            diagnostics: frontDoc.diagnostics + importRes.diagnostics
        )
    }

    /// Parses a skill folder containing a skill manifest file and optional supporting files.
    static func parseSkillDirectory(
        _ skillDir: URL,
        manifestURL: URL,
        scope: Scope,
        parentEnabled: Bool = true,
        in env: AgentEnvironment
    ) -> Artifact? {
        guard let rawData = try? env.fileSystem.contents(at: manifestURL) else {
            return nil
        }

        let location = AdapterPathNormalizer.sourceLocation(for: manifestURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: manifestURL, in: env)
        let id = ArtifactID(
            agent: .claudeCode,
            kind: .skill,
            scope: scope,
            path: identityPath
        )

        let fallbackName = skillDir.lastPathComponent
        guard let rawText = String(data: rawData, encoding: .utf8) else {
            let diag = Diagnostic(
                code: "skill.invalidUTF8",
                severity: .warning,
                message: "Skill manifest in '\(fallbackName)' is not valid UTF-8",
                location: location
            )
            return Artifact(
                id: id,
                agent: .claudeCode,
                kind: .skill,
                scope: scope,
                name: fallbackName,
                location: location,
                contentHash: ContentHasher.sha256Hex(rawData),
                enabled: false,
                loadMode: .never,
                payload: .other,
                diagnostics: [diag]
            )
        }

        let frontDoc = FrontmatterParser.parse(rawText, location: location)
        let frontmatter = frontDoc.frontmatter ?? [:]
        let skillName = nonEmptyString(frontmatter["name"]) ?? fallbackName
        let description = nonEmptyString(frontmatter["description"])
        let disableModelInvocation = boolValue(frontmatter["disable-model-invocation"]) == true

        let allFiles = AdapterPathNormalizer.collectFilesRecursively(
            under: skillDir,
            fileSystem: env.fileSystem
        ) { candidate in
            candidate.lastPathComponent != ClaudeCodePathCatalog.skillManifestFilename
                && candidate.lastPathComponent != ".DS_Store"
        }

        let supportingFiles = allFiles.compactMap { fileURL in
            AdapterPathNormalizer.relativePath(of: fileURL, from: skillDir, fileSystem: env.fileSystem)
        }.sorted()

        let effectiveLoadMode: LoadMode
        if !parentEnabled {
            effectiveLoadMode = .never
        } else if disableModelInvocation {
            effectiveLoadMode = .onInvoke
        } else {
            effectiveLoadMode = .frontmatterOnly
        }

        let skillDoc = SkillDoc(
            name: skillName,
            description: description,
            frontmatter: frontmatter,
            body: frontDoc.body,
            supportingFiles: supportingFiles
        )

        return Artifact(
            id: id,
            agent: .claudeCode,
            kind: .skill,
            scope: scope,
            name: skillName,
            location: location,
            contentHash: ContentHasher.sha256NormalizedText(rawText),
            enabled: parentEnabled,
            loadMode: effectiveLoadMode,
            payload: .skill(skillDoc),
            diagnostics: frontDoc.diagnostics
        )
    }

    /// Parses a custom subagent `.md` definition file.
    static func parseSubagentFile(
        at fileURL: URL,
        scope: Scope,
        parentEnabled: Bool = true,
        in env: AgentEnvironment
    ) -> Artifact? {
        guard let rawData = try? env.fileSystem.contents(at: fileURL) else {
            return nil
        }

        let location = AdapterPathNormalizer.sourceLocation(for: fileURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        let id = ArtifactID(
            agent: .claudeCode,
            kind: .subagent,
            scope: scope,
            path: identityPath
        )

        let fallbackName = fileURL.deletingPathExtension().lastPathComponent
        guard let rawText = String(data: rawData, encoding: .utf8) else {
            let diag = Diagnostic(
                code: "subagent.invalidUTF8",
                severity: .warning,
                message: "Subagent file '\(fileURL.lastPathComponent)' is not valid UTF-8",
                location: location
            )
            return Artifact(
                id: id,
                agent: .claudeCode,
                kind: .subagent,
                scope: scope,
                name: fallbackName,
                location: location,
                contentHash: ContentHasher.sha256Hex(rawData),
                enabled: false,
                loadMode: .never,
                payload: .other,
                diagnostics: [diag]
            )
        }

        let frontDoc = FrontmatterParser.parse(rawText, location: location)
        let frontmatter = frontDoc.frontmatter ?? [:]
        let name = nonEmptyString(frontmatter["name"]) ?? fallbackName
        let description = nonEmptyString(frontmatter["description"])
        let model = nonEmptyString(frontmatter["model"])
        let tools = extractToolsList(from: frontmatter["tools"])

        let doc = SubagentDoc(
            name: name,
            description: description,
            model: model,
            tools: tools,
            frontmatter: frontmatter,
            body: frontDoc.body
        )

        return Artifact(
            id: id,
            agent: .claudeCode,
            kind: .subagent,
            scope: scope,
            name: name,
            location: location,
            contentHash: ContentHasher.sha256NormalizedText(rawText),
            enabled: parentEnabled,
            loadMode: parentEnabled ? .frontmatterOnly : .never,
            payload: .subagent(doc),
            diagnostics: frontDoc.diagnostics
        )
    }

    /// Parses a custom slash command `.md` definition file.
    static func parseCommandFile(
        at fileURL: URL,
        commandsRoot: URL,
        scope: Scope,
        parentEnabled: Bool = true,
        in env: AgentEnvironment
    ) -> Artifact? {
        guard let rawData = try? env.fileSystem.contents(at: fileURL) else {
            return nil
        }

        let location = AdapterPathNormalizer.sourceLocation(for: fileURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        let id = ArtifactID(
            agent: .claudeCode,
            kind: .command,
            scope: scope,
            path: identityPath
        )

        let relPath =
            AdapterPathNormalizer.relativePath(of: fileURL, from: commandsRoot, fileSystem: env.fileSystem)
            ?? fileURL.lastPathComponent
        let withoutExt =
            relPath.hasSuffix(".md")
            ? String(relPath.dropLast(3))
            : relPath
        let commandName = withoutExt.replacingOccurrences(of: "/", with: ":")

        guard let rawText = String(data: rawData, encoding: .utf8) else {
            let diag = Diagnostic(
                code: "command.invalidUTF8",
                severity: .warning,
                message: "Command file '\(relPath)' is not valid UTF-8",
                location: location
            )
            return Artifact(
                id: id,
                agent: .claudeCode,
                kind: .command,
                scope: scope,
                name: commandName,
                location: location,
                contentHash: ContentHasher.sha256Hex(rawData),
                enabled: false,
                loadMode: .never,
                payload: .other,
                diagnostics: [diag]
            )
        }

        let frontDoc = FrontmatterParser.parse(rawText, location: location)
        let frontmatter = frontDoc.frontmatter ?? [:]
        let description = nonEmptyString(frontmatter["description"])
        let argumentHint =
            nonEmptyString(frontmatter["argument-hint"])
            ?? nonEmptyString(frontmatter["argumentHint"])

        let doc = CommandDoc(
            name: commandName,
            description: description,
            argumentHint: argumentHint,
            body: frontDoc.body
        )

        return Artifact(
            id: id,
            agent: .claudeCode,
            kind: .command,
            scope: scope,
            name: commandName,
            location: location,
            contentHash: ContentHasher.sha256NormalizedText(rawText),
            enabled: parentEnabled,
            loadMode: parentEnabled ? .onInvoke : .never,
            payload: .command(doc),
            diagnostics: frontDoc.diagnostics
        )
    }

    // MARK: - Primitive Extractors

    static func hashData(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            return ContentHasher.sha256NormalizedText(text)
        }
        return ContentHasher.sha256Hex(data)
    }

    static func stringValue(_ value: JSONValue?) -> String? {
        guard case .string(let str) = value else { return nil }
        return str
    }

    static func nonEmptyString(_ value: JSONValue?) -> String? {
        guard let raw = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    static func boolValue(_ value: JSONValue?) -> Bool? {
        guard case .bool(let flag) = value else { return nil }
        return flag
    }

    static func intValue(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let num):
            return Int(num)
        case .double(let dbl) where dbl.isFinite:
            return Int(dbl)
        default:
            return nil
        }
    }

    static func stringArray(_ value: JSONValue?) -> [String]? {
        guard case .array(let items) = value else { return nil }
        var result: [String] = []
        for item in items {
            if let str = stringValue(item) {
                result.append(str)
            }
        }
        return result
    }

    private static func extractPathGlobs(from frontmatter: [String: JSONValue]?) -> [String] {
        guard let frontmatter, let rawPaths = frontmatter["paths"] else {
            return []
        }
        switch rawPaths {
        case .array(let items):
            return items.compactMap { nonEmptyString($0) }
        case .string(let single):
            return
                single
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        default:
            return []
        }
    }

    private static func extractToolsList(from value: JSONValue?) -> [String]? {
        guard let value else { return nil }
        switch value {
        case .array(let arr):
            let list = arr.compactMap { nonEmptyString($0) }
            return list.isEmpty ? nil : list
        case .string(let commaSeparated):
            let list =
                commaSeparated
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return list.isEmpty ? nil : list
        default:
            return nil
        }
    }
}
