import BentoCore
import BentoParsing
import Foundation

/// Pure payload and structured-entry parsers for OpenAI Codex CLI configuration files.
enum CodexPayloadParser {
    struct ParsedTOMLConfig {
        let settingsArtifact: Artifact
        let mcpArtifacts: [Artifact]
        let hookArtifacts: [Artifact]
        let parsedTree: [String: JSONValue]?
    }

    /// Parses a Codex `config.toml` or `requirements.toml` file into a `.settings` artifact,
    /// `[mcp_servers.*]` artifacts (plus active profile MCP servers), and `[hooks]` / `notify` artifacts.
    static func parseTOMLConfig(
        at fileURL: URL,
        scope: Scope,
        enabled: Bool = true,
        activeProfileOverride: String? = nil,
        extractMCPAndHooks: Bool = true,
        in env: AgentEnvironment
    ) -> ParsedTOMLConfig {
        let location = AdapterPathNormalizer.sourceLocation(for: fileURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        let artifactID = ArtifactID(
            agent: .codex,
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
                message: "Cannot read Codex TOML file '\(fileURL.lastPathComponent)'",
                location: location
            )
            let fallback = Artifact(
                id: artifactID,
                agent: .codex,
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
            return ParsedTOMLConfig(
                settingsArtifact: fallback,
                mcpArtifacts: [],
                hookArtifacts: [],
                parsedTree: nil
            )
        }

        let contentHash = hashData(rawData)
        let (settingsDoc, diagnostics) = TOMLParser.parseSettings(rawData, location: location)

        guard let settingsDoc else {
            let malformed = Artifact(
                id: artifactID,
                agent: .codex,
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
            return ParsedTOMLConfig(
                settingsArtifact: malformed,
                mcpArtifacts: [],
                hookArtifacts: [],
                parsedTree: nil
            )
        }

        // Apply active `[profiles.<name>]` scalar overrides into an effective tree view for downstream consumers
        let effectiveTree = mergedWithActiveProfile(
            tree: settingsDoc.tree,
            activeProfileOverride: activeProfileOverride
        )

        let settingsArtifact = Artifact(
            id: artifactID,
            agent: .codex,
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

        guard extractMCPAndHooks else {
            return ParsedTOMLConfig(
                settingsArtifact: settingsArtifact,
                mcpArtifacts: [],
                hookArtifacts: [],
                parsedTree: effectiveTree
            )
        }

        let unredactedTree = try? TOMLParser.parseObject(rawData, redactSecrets: false)

        var mcpMap: [String: (keyPath: [String], dict: [String: JSONValue], rawBearerEnvVar: String?)] = [:]
        if case .object(let rootServers) = settingsDoc.tree["mcp_servers"] {
            let rawRootServers: [String: JSONValue]? =
                if case .object(let rawObj) = unredactedTree?["mcp_servers"] { rawObj } else { nil }
            for (name, val) in rootServers {
                if case .object(let dict) = val {
                    let rawBearer: String? =
                        if case .object(let rawServer) = rawRootServers?[name] {
                            validatedPOSIXEnvVarName(stringValue(rawServer["bearer_token_env_var"]))
                        } else {
                            nil
                        }
                    mcpMap[name] = (["mcp_servers", name], dict, rawBearer)
                }
            }
        }

        if let profileName = resolveActiveProfileName(from: settingsDoc.tree, override: activeProfileOverride),
            case .object(let profiles) = settingsDoc.tree["profiles"],
            case .object(let profileDict) = profiles[profileName],
            case .object(let profileServers) = profileDict["mcp_servers"]
        {
            let rawProfileServers: [String: JSONValue]? =
                if case .object(let rawProfiles) = unredactedTree?["profiles"],
                    case .object(let rawProf) = rawProfiles[profileName],
                    case .object(let rawServers) = rawProf["mcp_servers"]
                {
                    rawServers
                } else {
                    nil
                }
            for (name, val) in profileServers {
                if case .object(let dict) = val {
                    let rawBearer: String? =
                        if case .object(let rawServer) = rawProfileServers?[name] {
                            validatedPOSIXEnvVarName(stringValue(rawServer["bearer_token_env_var"]))
                        } else {
                            nil
                        }
                    mcpMap[name] = (["profiles", profileName, "mcp_servers", name], dict, rawBearer)
                }
            }
        }

        let mcpArtifacts = parseMCPServers(
            mcpMap,
            fileURL: fileURL,
            scope: scope,
            parentEnabled: enabled,
            contentHash: contentHash,
            in: env
        )

        let hookArtifacts = extractTOMLHooks(
            from: effectiveTree,
            fileURL: fileURL,
            scope: scope,
            enabled: enabled,
            contentHash: contentHash,
            in: env
        )

        return ParsedTOMLConfig(
            settingsArtifact: settingsArtifact,
            mcpArtifacts: mcpArtifacts,
            hookArtifacts: hookArtifacts,
            parsedTree: effectiveTree
        )
    }

    // MARK: - MCP Servers

    private static func parseMCPServers(
        _ servers: [String: (keyPath: [String], dict: [String: JSONValue], rawBearerEnvVar: String?)],
        fileURL: URL,
        scope: Scope,
        parentEnabled: Bool,
        contentHash: String,
        in env: AgentEnvironment
    ) -> [Artifact] {
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        var results: [Artifact] = []

        for serverName in servers.keys.sorted() {
            guard let entry = servers[serverName] else { continue }
            let serverDict = entry.dict
            let keyPath = entry.keyPath
            let location = AdapterPathNormalizer.sourceLocation(
                for: fileURL,
                keyPath: keyPath,
                in: env
            )
            let id = ArtifactID(
                agent: .codex,
                kind: .mcpServer,
                scope: scope,
                path: identityPath,
                keyPath: keyPath
            )

            var diagnostics: [Diagnostic] = []
            let transport: MCPServerConfig.Transport
            if let url = stringValue(serverDict["url"]) ?? stringValue(serverDict["http_url"]), !url.isEmpty {
                transport = .http(url: url)
            } else if let command = stringValue(serverDict["command"]), !command.isEmpty {
                let args = stringArray(serverDict["args"]) ?? []
                transport = .stdio(command: command, args: args)
            } else {
                transport = .stdio(command: "", args: [])
                diagnostics.append(
                    Diagnostic(
                        code: "mcp.missingTransport",
                        severity: .warning,
                        message: "Codex MCP server '\(serverName)' is missing 'command' or 'url'",
                        location: location
                    )
                )
            }

            var envKeySet: Set<String> = []
            if case .object(let envObj) = serverDict["env"] {
                envKeySet.formUnion(envObj.keys)
            }
            if let envVars = stringArray(serverDict["env_vars"]) {
                envKeySet.formUnion(envVars)
            }
            if let bearerVar = entry.rawBearerEnvVar
                ?? validatedPOSIXEnvVarName(stringValue(serverDict["bearer_token_env_var"]))
            {
                envKeySet.insert(bearerVar)
            }

            let enabledFlag = boolValue(serverDict["enabled"]) ?? true
            let isDisabled = !enabledFlag
            let isArtifactEnabled = parentEnabled && !isDisabled

            let allowedTools = stringArray(serverDict["enabled_tools"])
            let disabledTools = stringArray(serverDict["disabled_tools"])

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
                    agent: .codex,
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

    // MARK: - Hooks (`hooks.json` & `[hooks]` / `notify`)

    static func parseStandaloneHooksFile(
        at fileURL: URL,
        scope: Scope,
        enabled: Bool = true,
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
                agent: .codex,
                kind: .hook,
                scope: scope,
                path: identityPath
            )
            return [
                Artifact(
                    id: errID,
                    agent: .codex,
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

    private static func extractTOMLHooks(
        from tree: [String: JSONValue],
        fileURL: URL,
        scope: Scope,
        enabled: Bool,
        contentHash: String,
        in env: AgentEnvironment
    ) -> [Artifact] {
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        var results: [Artifact] = []

        // Top-level `notify = [...]` or `[hooks] notify = [...]`
        if let notifyTokens = stringArray(tree["notify"]), !notifyTokens.isEmpty {
            let command = notifyTokens.joined(separator: " ")
            results.append(
                makeHookArtifact(
                    event: "notify",
                    matcher: nil,
                    command: command,
                    timeoutSeconds: nil,
                    keyPath: ["notify"],
                    fileURL: fileURL,
                    identityPath: identityPath,
                    scope: scope,
                    enabled: enabled,
                    contentHash: contentHash,
                    in: env
                )
            )
        }

        if case .object(let hooksObj) = tree["hooks"] {
            if let notifyTokens = stringArray(hooksObj["notify"]), !notifyTokens.isEmpty {
                let command = notifyTokens.joined(separator: " ")
                results.append(
                    makeHookArtifact(
                        event: "notify",
                        matcher: nil,
                        command: command,
                        timeoutSeconds: nil,
                        keyPath: ["hooks", "notify"],
                        fileURL: fileURL,
                        identityPath: identityPath,
                        scope: scope,
                        enabled: enabled,
                        contentHash: contentHash,
                        in: env
                    )
                )
            }
            var eventSubmap = hooksObj
            eventSubmap.removeValue(forKey: "notify")
            results.append(
                contentsOf: extractEventHooksMap(
                    eventSubmap,
                    rootPrefix: ["hooks"],
                    fileURL: fileURL,
                    scope: scope,
                    enabled: enabled,
                    contentHash: contentHash,
                    in: env
                )
            )
        }

        return results
    }

    private static func extractEventHooksMap(
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
                        results.append(
                            makeHookArtifact(
                                event: eventName,
                                matcher: matcher,
                                command: command,
                                timeoutSeconds: timeout,
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
                } else if let directCommand = stringValue(groupDict["command"]), !directCommand.isEmpty {
                    let timeout = intValue(groupDict["timeout"])
                    let keyPath = rootPrefix + [eventName, "\(groupIndex)"]
                    results.append(
                        makeHookArtifact(
                            event: eventName,
                            matcher: matcher,
                            command: directCommand,
                            timeoutSeconds: timeout,
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
            agent: .codex,
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
            agent: .codex,
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

    // MARK: - Rules (`AGENTS.md`, `AGENTS.override.md`, Fallbacks)

    static func parseRulesFile(
        at fileURL: URL,
        scope: Scope,
        name: String,
        loadMode: LoadMode,
        wasTruncated: Bool,
        maxBytes: Int?,
        in env: AgentEnvironment
    ) -> Artifact {
        let location = AdapterPathNormalizer.sourceLocation(for: fileURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        let id = ArtifactID(
            agent: .codex,
            kind: .rules,
            scope: scope,
            path: identityPath
        )

        let rawData: Data
        do {
            rawData = try env.fileSystem.contents(at: fileURL)
        } catch {
            let diag = Diagnostic(
                code: "rules.readFailed",
                severity: .error,
                message: "Cannot read Codex instruction file '\(fileURL.lastPathComponent)'",
                location: location
            )
            return Artifact(
                id: id,
                agent: .codex,
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

        let contentHash = hashData(rawData)
        guard let text = String(data: rawData, encoding: .utf8) else {
            let diag = Diagnostic(
                code: "rules.invalidUTF8",
                severity: .error,
                message: "Codex instruction file '\(fileURL.lastPathComponent)' is not valid UTF-8",
                location: location
            )
            return Artifact(
                id: id,
                agent: .codex,
                kind: .rules,
                scope: scope,
                name: name,
                location: location,
                contentHash: contentHash,
                enabled: false,
                loadMode: .never,
                payload: .other,
                diagnostics: [diag]
            )
        }

        var diagnostics: [Diagnostic] = []
        if wasTruncated, let maxBytes {
            diagnostics.append(
                Diagnostic(
                    code: "rules.truncated",
                    severity: .warning,
                    message:
                        "Codex instruction file '\(name)' exceeds cumulative project_doc_max_bytes limit (\(maxBytes) bytes)",
                    location: location
                )
            )
        }

        let doc = RulesDoc(
            content: text,
            imports: [],
            frontmatter: nil,
            byteCount: rawData.count,
            characterCount: text.count,
            wasTruncated: wasTruncated
        )

        return Artifact(
            id: id,
            agent: .codex,
            kind: .rules,
            scope: scope,
            name: name,
            location: location,
            contentHash: contentHash,
            enabled: true,
            loadMode: loadMode,
            payload: .rules(doc),
            diagnostics: diagnostics
        )
    }

    // MARK: - Skills (`SKILL.md`)

    static func parseSkill(
        skillDirectory: URL,
        manifestURL: URL,
        scope: Scope,
        enabled: Bool = true,
        in env: AgentEnvironment
    ) -> Artifact {
        let location = AdapterPathNormalizer.sourceLocation(for: manifestURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: manifestURL, in: env)
        let id = ArtifactID(
            agent: .codex,
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
                message: "Cannot read skill manifest '\(manifestURL.path)'",
                location: location
            )
            return Artifact(
                id: id,
                agent: .codex,
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
        guard let text = String(data: rawData, encoding: .utf8) else {
            let diag = Diagnostic(
                code: "skill.invalidUTF8",
                severity: .error,
                message: "Skill manifest '\(manifestURL.path)' is not valid UTF-8",
                location: location
            )
            return Artifact(
                id: id,
                agent: .codex,
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

        let frontmatterDoc = FrontmatterParser.parse(text, location: location)
        let fm = frontmatterDoc.frontmatter ?? [:]
        let body = frontmatterDoc.body

        let skillName = nonEmptyString(fm["name"]) ?? fallbackName
        let description = nonEmptyString(fm["description"])

        let supportingFiles = AdapterPathNormalizer.collectFilesRecursively(
            under: skillDirectory,
            fileSystem: env.fileSystem
        ) { candidate in
            candidate.standardizedFileURL.path != manifestURL.standardizedFileURL.path
                && candidate.lastPathComponent != ".DS_Store"
        }.compactMap { candidate in
            AdapterPathNormalizer.relativePath(of: candidate, from: skillDirectory, fileSystem: env.fileSystem)
        }.sorted()

        let doc = SkillDoc(
            name: skillName,
            description: description,
            frontmatter: fm,
            body: body,
            supportingFiles: supportingFiles
        )

        return Artifact(
            id: id,
            agent: .codex,
            kind: .skill,
            scope: scope,
            name: skillName,
            location: location,
            contentHash: contentHash,
            enabled: enabled,
            loadMode: enabled ? .frontmatterOnly : .never,
            payload: .skill(doc),
            diagnostics: frontmatterDoc.diagnostics
        )
    }

    // MARK: - Profile & Value Helpers

    private static func resolveActiveProfileName(from tree: [String: JSONValue], override: String?) -> String? {
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        return nonEmptyString(tree["profile"])
    }

    private static func mergedWithActiveProfile(
        tree: [String: JSONValue],
        activeProfileOverride: String?
    ) -> [String: JSONValue] {
        guard let profileName = resolveActiveProfileName(from: tree, override: activeProfileOverride),
            case .object(let profiles) = tree["profiles"],
            case .object(let profileDict) = profiles[profileName]
        else {
            return tree
        }
        var merged = tree
        for (key, value) in profileDict where key != "mcp_servers" {
            merged[key] = value
        }
        return merged
    }

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
        guard let str = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !str.isEmpty
        else {
            return nil
        }
        return str
    }

    static func boolValue(_ value: JSONValue?) -> Bool? {
        guard case .bool(let flag) = value else { return nil }
        return flag
    }

    static func intValue(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let intVal):
            return Int(intVal)
        case .double(let dblVal):
            return Int(dblVal)
        default:
            return nil
        }
    }

    static func stringArray(_ value: JSONValue?) -> [String]? {
        if case .array(let items) = value {
            let strings = items.compactMap { item -> String? in
                guard case .string(let s) = item else { return nil }
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return strings
        }
        return nil
    }

    /// Validates that `candidate` is a POSIX uppercase environment variable identifier (`^[A-Z_][A-Z0-9_]*$`),
    /// preventing accidental secret values from ever entering `MCPServerConfig.envKeys`.
    private static func validatedPOSIXEnvVarName(_ candidate: String?) -> String? {
        guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty,
            trimmed.count <= 128,
            trimmed != SecretRedactor.marker
        else {
            return nil
        }
        guard let first = trimmed.unicodeScalars.first,
            (first.value >= 65 && first.value <= 90) || first == "_"
        else {
            return nil
        }
        for scalar in trimmed.unicodeScalars {
            let isUpper = scalar.value >= 65 && scalar.value <= 90
            let isDigit = scalar.value >= 48 && scalar.value <= 57
            if !isUpper && !isDigit && scalar != "_" {
                return nil
            }
        }
        return trimmed
    }
}
