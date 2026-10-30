import BentoCore
import BentoParsing
import Foundation

/// Pure payload and structured-entry parsers for Google Gemini CLI configuration, extension, command, skill, and context files.
enum GeminiPayloadParser {
    struct ParsedSettingsConfig {
        let settingsArtifact: Artifact
        let mcpArtifacts: [Artifact]
        let hookArtifacts: [Artifact]
        let parsedTree: [String: JSONValue]?
    }

    // MARK: - Settings (`settings.json` / `system-defaults.json`)

    static func parseSettingsFile(
        at fileURL: URL,
        scope: Scope,
        enabled: Bool = true,
        in env: AgentEnvironment
    ) -> ParsedSettingsConfig {
        let location = AdapterPathNormalizer.sourceLocation(for: fileURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        let artifactID = ArtifactID(
            agent: .gemini,
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
                message: "Cannot read Gemini CLI settings file '\(fileURL.lastPathComponent)'",
                location: location
            )
            let fallback = Artifact(
                id: artifactID,
                agent: .gemini,
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
            return ParsedSettingsConfig(
                settingsArtifact: fallback,
                mcpArtifacts: [],
                hookArtifacts: [],
                parsedTree: nil
            )
        }

        let contentHash = hashData(rawData)
        let (settingsDoc, diagnostics) = JSONCParser.parseSettings(rawData, location: location)

        guard let settingsDoc else {
            let malformed = Artifact(
                id: artifactID,
                agent: .gemini,
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
            return ParsedSettingsConfig(
                settingsArtifact: malformed,
                mcpArtifacts: [],
                hookArtifacts: [],
                parsedTree: nil
            )
        }

        let settingsArtifact = Artifact(
            id: artifactID,
            agent: .gemini,
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

        var mcpArtifacts: [Artifact] = []
        if case .object(let serversMap) = settingsDoc.tree["mcpServers"] {
            mcpArtifacts = parseMCPServersDictionary(
                serversMap,
                keyPrefix: ["mcpServers"],
                fileURL: fileURL,
                scope: scope,
                parentEnabled: enabled,
                contentHash: contentHash,
                in: env
            )
        }

        var hookArtifacts: [Artifact] = []
        if case .object(let hooksMap) = settingsDoc.tree["hooks"] {
            hookArtifacts = extractEventHooksMap(
                hooksMap,
                rootPrefix: ["hooks"],
                fileURL: fileURL,
                scope: scope,
                enabled: enabled,
                contentHash: contentHash,
                in: env
            )
        }

        return ParsedSettingsConfig(
            settingsArtifact: settingsArtifact,
            mcpArtifacts: mcpArtifacts,
            hookArtifacts: hookArtifacts,
            parsedTree: settingsDoc.tree
        )
    }

    // MARK: - MCP Servers (`mcpServers`)

    static func parseMCPServersDictionary(
        _ serversMap: [String: JSONValue],
        keyPrefix: [String],
        fileURL: URL,
        scope: Scope,
        parentEnabled: Bool,
        contentHash: String,
        in env: AgentEnvironment
    ) -> [Artifact] {
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        var results: [Artifact] = []

        for serverName in serversMap.keys.sorted() {
            guard case .object(let serverDict) = serversMap[serverName] else { continue }
            let keyPath = keyPrefix + [serverName]
            let location = AdapterPathNormalizer.sourceLocation(
                for: fileURL,
                keyPath: keyPath,
                in: env
            )
            let id = ArtifactID(
                agent: .gemini,
                kind: .mcpServer,
                scope: scope,
                path: identityPath,
                keyPath: keyPath
            )

            var diagnostics: [Diagnostic] = []
            let transport: MCPServerConfig.Transport
            if let httpURL = nonEmptyString(serverDict["httpUrl"]) {
                transport = .http(url: httpURL)
            } else if let sseURL = nonEmptyString(serverDict["url"]) {
                transport = .sse(url: sseURL)
            } else if let command = nonEmptyString(serverDict["command"]) {
                let args = stringArray(serverDict["args"]) ?? []
                transport = .stdio(command: command, args: args)
            } else {
                transport = .stdio(command: "", args: [])
                diagnostics.append(
                    Diagnostic(
                        code: "mcp.missingTransport",
                        severity: .warning,
                        message: "Gemini CLI MCP server '\(serverName)' is missing 'command', 'url', or 'httpUrl'",
                        location: location
                    )
                )
            }

            var envKeySet: Set<String> = []
            if case .object(let envObj) = serverDict["env"] {
                envKeySet.formUnion(envObj.keys)
            }

            let isDisabled =
                (boolValue(serverDict["disabled"]) == true)
                || (boolValue(serverDict["enabled"]) == false)
            let isArtifactEnabled = parentEnabled && !isDisabled

            let allowedTools = stringArray(serverDict["includeTools"])
            let disabledTools = stringArray(serverDict["excludeTools"])

            let config = MCPServerConfig(
                transport: transport,
                envKeys: envKeySet.sorted(),
                disabled: isDisabled,
                allowedTools: allowedTools,
                disabledTools: disabledTools
            )

            results.append(
                Artifact(
                    id: id,
                    agent: .gemini,
                    kind: .mcpServer,
                    scope: scope,
                    name: serverName,
                    location: location,
                    contentHash: contentHash,
                    enabled: isArtifactEnabled,
                    loadMode: isArtifactEnabled ? .always : .never,
                    payload: .mcpServer(config),
                    diagnostics: diagnostics
                )
            )
        }

        return results
    }

    // MARK: - Hooks (`hooks` in settings & extension `hooks/hooks.json`)

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
                agent: .gemini,
                kind: .hook,
                scope: scope,
                path: identityPath
            )
            return [
                Artifact(
                    id: errID,
                    agent: .gemini,
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

        let hooksMap: [String: JSONValue]
        let rootPrefix: [String]
        if case .object(let nested) = tree["hooks"] {
            hooksMap = nested
            rootPrefix = ["hooks"]
        } else {
            hooksMap = tree
            rootPrefix = []
        }

        return extractEventHooksMap(
            hooksMap,
            rootPrefix: rootPrefix,
            fileURL: fileURL,
            scope: scope,
            enabled: enabled,
            contentHash: contentHash,
            in: env
        )
    }

    static func extractEventHooksMap(
        _ hooksMap: [String: JSONValue],
        rootPrefix: [String],
        fileURL: URL,
        scope: Scope,
        enabled: Bool,
        contentHash: String,
        in env: AgentEnvironment
    ) -> [Artifact] {
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        var results: [Artifact] = []

        for eventName in hooksMap.keys.sorted() {
            guard case .array(let groups) = hooksMap[eventName] else { continue }
            for (groupIndex, groupValue) in groups.enumerated() {
                guard case .object(let groupDict) = groupValue else { continue }
                let matcher = nonEmptyString(groupDict["matcher"])

                if case .array(let innerHooks) = groupDict["hooks"] {
                    for (hookIndex, innerValue) in innerHooks.enumerated() {
                        guard case .object(let hookDict) = innerValue,
                            let command = nonEmptyString(hookDict["command"])
                        else {
                            continue
                        }
                        let timeoutSeconds = normalizeHookTimeoutSeconds(intValue(hookDict["timeout"]))
                        let keyPath = rootPrefix + [eventName, "\(groupIndex)", "hooks", "\(hookIndex)"]
                        results.append(
                            makeHookArtifact(
                                event: eventName,
                                matcher: matcher,
                                command: command,
                                timeoutSeconds: timeoutSeconds,
                                keyPath: keyPath,
                                fileURL: fileURL,
                                identityPath: identityPath,
                                scope: scope,
                                enabled: enabled,
                                contentHash: contentHash,
                                in: env
                            )
                        )
                    }
                } else if let directCommand = nonEmptyString(groupDict["command"]) {
                    let timeoutSeconds = normalizeHookTimeoutSeconds(intValue(groupDict["timeout"]))
                    let keyPath = rootPrefix + [eventName, "\(groupIndex)"]
                    results.append(
                        makeHookArtifact(
                            event: eventName,
                            matcher: matcher,
                            command: directCommand,
                            timeoutSeconds: timeoutSeconds,
                            keyPath: keyPath,
                            fileURL: fileURL,
                            identityPath: identityPath,
                            scope: scope,
                            enabled: enabled,
                            contentHash: contentHash,
                            in: env
                        )
                    )
                }
            }
        }

        return results
    }

    /// Gemini CLI configures hook timeouts in milliseconds (default `60000`); convert values `>= 1000` to seconds.
    private static func normalizeHookTimeoutSeconds(_ rawTimeout: Int?) -> Int? {
        guard let rawTimeout, rawTimeout > 0 else { return nil }
        return rawTimeout >= 1_000 ? (rawTimeout / 1_000) : rawTimeout
    }

    private static func makeHookArtifact(
        event: String,
        matcher: String?,
        command: String,
        timeoutSeconds: Int?,
        keyPath: [String],
        fileURL: URL,
        identityPath: String,
        scope: Scope,
        enabled: Bool,
        contentHash: String,
        in env: AgentEnvironment
    ) -> Artifact {
        let displayName =
            if let matcher, !matcher.isEmpty {
                "\(event) (\(matcher))"
            } else {
                event
            }
        let location = AdapterPathNormalizer.sourceLocation(
            for: fileURL,
            keyPath: keyPath,
            in: env
        )
        let id = ArtifactID(
            agent: .gemini,
            kind: .hook,
            scope: scope,
            path: identityPath,
            keyPath: keyPath
        )
        let config = HookConfig(
            event: event,
            matcher: matcher,
            command: command,
            timeoutSeconds: timeoutSeconds
        )
        return Artifact(
            id: id,
            agent: .gemini,
            kind: .hook,
            scope: scope,
            name: displayName,
            location: location,
            contentHash: contentHash,
            enabled: enabled,
            loadMode: enabled ? .onInvoke : .never,
            payload: .hook(config),
            diagnostics: []
        )
    }

    // MARK: - Skills

    static func parseSkill(
        skillDirectory: URL,
        manifestURL: URL,
        scope: Scope,
        enabled: Bool,
        in env: AgentEnvironment
    ) -> Artifact {
        let location = AdapterPathNormalizer.sourceLocation(for: manifestURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: manifestURL, in: env)
        let id = ArtifactID(
            agent: .gemini,
            kind: .skill,
            scope: scope,
            path: identityPath
        )
        let fallbackName = skillDirectory.lastPathComponent

        let rawData: Data
        do {
            rawData = try env.fileSystem.contents(at: manifestURL)
        } catch {
            let diag = Diagnostic(
                code: "skill.readFailed",
                severity: .error,
                message: "Cannot read Gemini skill manifest in '\(fallbackName)'",
                location: location
            )
            return Artifact(
                id: id,
                agent: .gemini,
                kind: .skill,
                scope: scope,
                name: fallbackName,
                location: location,
                contentHash: ContentHasher.sha256Hex(Data()),
                enabled: false,
                loadMode: .never,
                payload: .other,
                diagnostics: [diag]
            )
        }

        let contentHash = hashData(rawData)
        guard let rawText = String(data: rawData, encoding: .utf8) else {
            let diag = Diagnostic(
                code: "skill.invalidUTF8",
                severity: .warning,
                message: "Skill manifest in '\(fallbackName)' is not valid UTF-8",
                location: location
            )
            return Artifact(
                id: id,
                agent: .gemini,
                kind: .skill,
                scope: scope,
                name: fallbackName,
                location: location,
                contentHash: contentHash,
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

        let supportingFiles = AdapterPathNormalizer.collectFilesRecursively(
            under: skillDirectory,
            fileSystem: env.fileSystem
        ) { candidate in
            candidate.standardizedFileURL.path != manifestURL.standardizedFileURL.path
                && !GeminiPathCatalog.isFinderMetadataFile(candidate)
        }.compactMap { candidate in
            AdapterPathNormalizer.relativePath(of: candidate, from: skillDirectory, fileSystem: env.fileSystem)
        }.sorted()

        let doc = SkillDoc(
            name: skillName,
            description: description,
            frontmatter: frontmatter,
            body: frontDoc.body,
            supportingFiles: supportingFiles
        )

        return Artifact(
            id: id,
            agent: .gemini,
            kind: .skill,
            scope: scope,
            name: skillName,
            location: location,
            contentHash: contentHash,
            enabled: enabled,
            loadMode: enabled ? .frontmatterOnly : .never,
            payload: .skill(doc),
            diagnostics: frontDoc.diagnostics
        )
    }

    // MARK: - Subagents (`agents/**/*.md`)

    static func parseSubagentFile(
        at fileURL: URL,
        scope: Scope,
        enabled: Bool,
        in env: AgentEnvironment
    ) -> Artifact? {
        guard let rawData = try? env.fileSystem.contents(at: fileURL) else {
            return nil
        }

        let location = AdapterPathNormalizer.sourceLocation(for: fileURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        let id = ArtifactID(
            agent: .gemini,
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
                agent: .gemini,
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

        let frontmatterEnabled = boolValue(frontmatter["enabled"]) ?? true
        let isEffectiveEnabled = enabled && frontmatterEnabled

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
            agent: .gemini,
            kind: .subagent,
            scope: scope,
            name: name,
            location: location,
            contentHash: ContentHasher.sha256NormalizedText(rawText),
            enabled: isEffectiveEnabled,
            loadMode: isEffectiveEnabled ? .frontmatterOnly : .never,
            payload: .subagent(doc),
            diagnostics: frontDoc.diagnostics
        )
    }

    // MARK: - Custom TOML Commands (`commands/**/*.toml`)

    static func parseCommandFile(
        at fileURL: URL,
        commandsRoot: URL,
        scope: Scope,
        enabled: Bool,
        in env: AgentEnvironment
    ) -> Artifact? {
        guard let rawData = try? env.fileSystem.contents(at: fileURL) else {
            return nil
        }

        let location = AdapterPathNormalizer.sourceLocation(for: fileURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        let id = ArtifactID(
            agent: .gemini,
            kind: .command,
            scope: scope,
            path: identityPath
        )

        let relPath =
            AdapterPathNormalizer.relativePath(of: fileURL, from: commandsRoot, fileSystem: env.fileSystem)
            ?? fileURL.lastPathComponent
        let extSuffix = "." + GeminiPathCatalog.commandFileExtension
        let withoutExt =
            relPath.lowercased().hasSuffix(extSuffix)
            ? String(relPath.dropLast(extSuffix.count))
            : relPath
        let commandName = withoutExt.replacingOccurrences(of: "/", with: ":")

        let contentHash = hashData(rawData)
        let (settingsDoc, parseDiagnostics) = TOMLParser.parseSettings(rawData, location: location)

        guard let tree = settingsDoc?.tree else {
            return Artifact(
                id: id,
                agent: .gemini,
                kind: .command,
                scope: scope,
                name: commandName,
                location: location,
                contentHash: contentHash,
                enabled: false,
                loadMode: .never,
                payload: .other,
                diagnostics: parseDiagnostics
            )
        }

        var diagnostics = parseDiagnostics
        let prompt = stringValue(tree["prompt"]) ?? ""
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append(
                Diagnostic(
                    code: "command.missingPrompt",
                    severity: .warning,
                    message: "Gemini TOML command '\(commandName)' is missing a non-empty 'prompt' field",
                    location: location
                )
            )
        }

        let description = nonEmptyString(tree["description"])
        let explicitHint = nonEmptyString(tree["argumentHint"]) ?? nonEmptyString(tree["argument_hint"])
        let argumentHint = explicitHint ?? (prompt.contains("{{args}}") ? "{{args}}" : nil)

        let doc = CommandDoc(
            name: commandName,
            description: description,
            argumentHint: argumentHint,
            body: prompt
        )

        return Artifact(
            id: id,
            agent: .gemini,
            kind: .command,
            scope: scope,
            name: commandName,
            location: location,
            contentHash: contentHash,
            enabled: enabled,
            loadMode: enabled ? .onInvoke : .never,
            payload: .command(doc),
            diagnostics: diagnostics
        )
    }

    // MARK: - Ignore File

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
            agent: .gemini,
            kind: .ignoreFile,
            scope: scope,
            path: identityPath
        )

        return Artifact(
            id: id,
            agent: .gemini,
            kind: .ignoreFile,
            scope: scope,
            name: fileURL.lastPathComponent,
            location: location,
            contentHash: hashData(rawData),
            enabled: true,
            loadMode: .never,
            payload: .other,
            diagnostics: []
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
        guard let raw = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
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
            if let str = nonEmptyString(item) {
                result.append(str)
            }
        }
        return result
    }

    static func stringOrArray(_ value: JSONValue?) -> [String]? {
        if let single = nonEmptyString(value) {
            return [single]
        }
        if let list = stringArray(value), !list.isEmpty {
            return list
        }
        return nil
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
