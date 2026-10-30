import BentoCore
import BentoParsing
import Foundation

/// Pure payload and structured-entry parsers for GitHub Copilot CLI configuration files.
enum CopilotPayloadParser {
    /// Parses a JSON/JSONC settings or state file (`config.json`, `settings.json`) and any embedded `hooks`.
    static func parseSettingsAndHooks(
        at fileURL: URL,
        scope: Scope,
        in env: AgentEnvironment
    ) -> (settingsArtifact: Artifact, hookArtifacts: [Artifact]) {
        let location = AdapterPathNormalizer.sourceLocation(for: fileURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        let artifactID = ArtifactID(
            agent: .copilot,
            kind: .settings,
            scope: scope,
            path: identityPath
        )

        guard let rawData = try? env.fileSystem.contents(at: fileURL) else {
            let diag = Diagnostic(
                code: "settings.readFailed",
                severity: .error,
                message: "Cannot read Copilot settings file '\(fileURL.lastPathComponent)'",
                location: location
            )
            let fallback = Artifact(
                id: artifactID,
                agent: .copilot,
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
            return (fallback, [])
        }

        let contentHash = hashData(rawData)
        let (settingsDoc, diagnostics) = JSONCParser.parseSettings(rawData, location: location)

        guard let settingsDoc else {
            let malformed = Artifact(
                id: artifactID,
                agent: .copilot,
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
            return (malformed, [])
        }

        let settingsArtifact = Artifact(
            id: artifactID,
            agent: .copilot,
            kind: .settings,
            scope: scope,
            name: fileURL.lastPathComponent,
            location: location,
            contentHash: contentHash,
            enabled: true,
            loadMode: .never,
            payload: .settings(settingsDoc),
            diagnostics: diagnostics
        )

        let hooks = extractHooks(
            from: settingsDoc.tree,
            fileURL: fileURL,
            scope: scope,
            contentHash: contentHash,
            in: env
        )

        return (settingsArtifact, hooks)
    }

    /// Parses a standalone Copilot hook JSON file (`~/.copilot/hooks/*.json`, `<repo>/.github/hooks/*.json`).
    static func parseHooksFile(
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
                agent: .copilot,
                kind: .hook,
                scope: scope,
                path: identityPath
            )
            return [
                Artifact(
                    id: errID,
                    agent: .copilot,
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
            contentHash: contentHash,
            in: env
        )
    }

    /// Extracts `.hook` artifacts from Copilot CLI `hooks.<event>` arrays.
    static func extractHooks(
        from tree: [String: JSONValue],
        fileURL: URL,
        scope: Scope,
        contentHash: String,
        in env: AgentEnvironment
    ) -> [Artifact] {
        guard case .object(let hooksMap) = tree["hooks"] else {
            return []
        }

        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        var results: [Artifact] = []

        for eventName in hooksMap.keys.sorted() {
            guard case .array(let entries) = hooksMap[eventName] else { continue }
            for (index, entryVal) in entries.enumerated() {
                guard case .object(let entryDict) = entryVal else { continue }
                let matcher = nonEmptyString(entryDict["matcher"])

                if case .array(let nested) = entryDict["hooks"] {
                    for (innerIdx, innerVal) in nested.enumerated() {
                        guard case .object(let innerDict) = innerVal,
                            let command = nonEmptyString(innerDict["bash"])
                                ?? nonEmptyString(innerDict["command"])
                        else {
                            continue
                        }
                        let timeout = intValue(innerDict["timeoutSec"]) ?? intValue(innerDict["timeout"])
                        let keyPath = ["hooks", eventName, "\(index)", "hooks", "\(innerIdx)"]
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
                                contentHash: contentHash,
                                in: env
                            )
                        )
                    }
                } else if let command = nonEmptyString(entryDict["bash"])
                    ?? nonEmptyString(entryDict["command"])
                {
                    let timeout = intValue(entryDict["timeoutSec"]) ?? intValue(entryDict["timeout"])
                    let keyPath = ["hooks", eventName, "\(index)"]
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
        contentHash: String,
        in env: AgentEnvironment
    ) -> Artifact {
        let displayName =
            if let matcher {
                "\(event) (\(matcher))"
            } else {
                event
            }
        let location = AdapterPathNormalizer.sourceLocation(for: fileURL, keyPath: keyPath, in: env)
        let id = ArtifactID(
            agent: .copilot,
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
            agent: .copilot,
            kind: .hook,
            scope: scope,
            name: displayName,
            location: location,
            contentHash: contentHash,
            enabled: true,
            loadMode: .onInvoke,
            payload: .hook(config)
        )
    }

    // MARK: - MCP Configuration (`mcp-config.json`, `.github/mcp.json`, `.vscode/mcp.json`)

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
                agent: .copilot,
                kind: .mcpServer,
                scope: scope,
                path: identityPath
            )
            return [
                Artifact(
                    id: errID,
                    agent: .copilot,
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

        let serversMap: [String: JSONValue]
        let rootKey: String
        if case .object(let mcpServers) = tree["mcpServers"] {
            serversMap = mcpServers
            rootKey = "mcpServers"
        } else if case .object(let vscodeServers) = tree["servers"] {
            serversMap = vscodeServers
            rootKey = "servers"
        } else {
            return []
        }

        var results: [Artifact] = []
        for serverName in serversMap.keys.sorted() {
            guard case .object(let serverDict) = serversMap[serverName] else { continue }
            let keyPath = [rootKey, serverName]
            let location = AdapterPathNormalizer.sourceLocation(for: fileURL, keyPath: keyPath, in: env)
            let id = ArtifactID(
                agent: .copilot,
                kind: .mcpServer,
                scope: scope,
                path: identityPath,
                keyPath: keyPath
            )

            var itemDiagnostics: [Diagnostic] = []
            let rawType = nonEmptyString(serverDict["type"])?.lowercased()
            let url = nonEmptyString(serverDict["url"]) ?? nonEmptyString(serverDict["httpUrl"])
            let command = nonEmptyString(serverDict["command"])

            let transport: MCPServerConfig.Transport
            if rawType == "sse", let url {
                transport = .sse(url: url)
            } else if let url, rawType == "http" || command == nil {
                if url.lowercased().hasSuffix("/sse") && rawType == nil {
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
                        message: "Copilot MCP server '\(serverName)' is missing 'command' or 'url'",
                        location: location
                    )
                )
            }

            var envKeys: [String] = []
            if case .object(let envObj) = serverDict["env"] {
                envKeys = envObj.keys.sorted()
            }

            let explicitlyDisabled =
                (boolValue(serverDict["disabled"]) == true) || (boolValue(serverDict["enabled"]) == false)
            let allowedTools =
                parseCopilotToolsFilter(serverDict["tools"])
                ?? stringArray(serverDict["allowedTools"])
            let disabledTools = stringArray(serverDict["disabledTools"])

            let config = MCPServerConfig(
                transport: transport,
                envKeys: envKeys,
                disabled: explicitlyDisabled,
                allowedTools: allowedTools,
                disabledTools: disabledTools
            )

            results.append(
                Artifact(
                    id: id,
                    agent: .copilot,
                    kind: .mcpServer,
                    scope: scope,
                    name: serverName,
                    location: location,
                    contentHash: contentHash,
                    enabled: !explicitlyDisabled,
                    loadMode: explicitlyDisabled ? .never : .always,
                    payload: .mcpServer(config),
                    diagnostics: itemDiagnostics
                )
            )
        }

        return results
    }

    private static func parseCopilotToolsFilter(_ value: JSONValue?) -> [String]? {
        guard let list = stringArray(value) else { return nil }
        if list.contains("*") {
            return nil
        }
        return list
    }

    // MARK: - Rules (`copilot-instructions.md`, `*.instructions.md`, `AGENTS.md`)

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
            agent: .copilot,
            kind: .rules,
            scope: scope,
            path: identityPath
        )

        guard let rawData = try? env.fileSystem.contents(at: fileURL) else {
            let diag = Diagnostic(
                code: "rules.readFailed",
                severity: .error,
                message: "Cannot read Copilot instructions file '\(fileURL.lastPathComponent)'",
                location: location
            )
            return Artifact(
                id: id,
                agent: .copilot,
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
                message: "Copilot instructions file '\(fileURL.lastPathComponent)' is not valid UTF-8",
                location: location
            )
            return Artifact(
                id: id,
                agent: .copilot,
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
            agent: .copilot,
            kind: .rules,
            scope: scope,
            name: name,
            location: location,
            contentHash: contentHash,
            enabled: true,
            loadMode: loadMode,
            payload: .rules(doc)
        )
    }

    /// Parses `.github/instructions/**/*.instructions.md` and maps YAML frontmatter `applyTo` to `LoadMode.conditional`.
    static func parseModularInstructionFile(
        at fileURL: URL,
        scope: Scope,
        displayName: String,
        in env: AgentEnvironment
    ) -> Artifact {
        let location = AdapterPathNormalizer.sourceLocation(for: fileURL, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: fileURL, in: env)
        let id = ArtifactID(
            agent: .copilot,
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
                message: "Cannot read Copilot modular instruction file '\(fileURL.lastPathComponent)'",
                location: location
            )
            return Artifact(
                id: id,
                agent: .copilot,
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
        let parsed = FrontmatterParser.parse(text, location: location, redactSecrets: true)
        let applyToGlobs = extractGlobs(from: parsed.frontmatter?["applyTo"])

        let loadMode: LoadMode =
            if !applyToGlobs.isEmpty {
                .conditional(globs: applyToGlobs)
            } else {
                .always
            }

        let doc = RulesDoc(
            content: parsed.body,
            imports: [],
            frontmatter: parsed.frontmatter,
            byteCount: rawData.count,
            characterCount: text.count,
            wasTruncated: false
        )

        return Artifact(
            id: id,
            agent: .copilot,
            kind: .rules,
            scope: scope,
            name: displayName,
            location: location,
            contentHash: contentHash,
            enabled: true,
            loadMode: loadMode,
            payload: .rules(doc),
            diagnostics: parsed.diagnostics
        )
    }

    // MARK: - Skills, Subagents & Prompt Commands

    static func parseSkillDirectory(
        at skillDir: URL,
        scope: Scope,
        in env: AgentEnvironment
    ) -> Artifact? {
        let fs = env.fileSystem
        let skillFile = CopilotPathCatalog.skillMarkdownFile(in: skillDir)
        guard AdapterPathNormalizer.isEffectiveFile(skillFile, fileSystem: fs) else {
            return nil
        }

        let location = AdapterPathNormalizer.sourceLocation(for: skillFile, in: env)
        let identityPath = AdapterPathNormalizer.canonicalIdentityPath(for: skillFile, in: env)
        let id = ArtifactID(
            agent: .copilot,
            kind: .skill,
            scope: scope,
            path: identityPath
        )

        guard let rawData = try? fs.contents(at: skillFile),
            let text = String(data: rawData, encoding: .utf8)
        else {
            return nil
        }

        let contentHash = hashData(rawData)
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
            agent: .copilot,
            kind: .skill,
            scope: scope,
            name: skillName,
            location: location,
            contentHash: contentHash,
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
            agent: .copilot,
            kind: .subagent,
            scope: scope,
            path: identityPath
        )
        let contentHash = hashData(rawData)
        let parsed = FrontmatterParser.parse(text, location: location, redactSecrets: true)
        let frontmatter = parsed.frontmatter ?? [:]

        let name = nonEmptyString(frontmatter["name"]) ?? CopilotPathCatalog.defaultAgentName(for: fileURL)
        let description = nonEmptyString(frontmatter["description"])
        let model = nonEmptyString(frontmatter["model"])
        let tools = extractGlobs(from: frontmatter["tools"])

        let doc = SubagentDoc(
            name: name,
            description: description,
            model: model,
            tools: tools.isEmpty ? nil : tools,
            frontmatter: frontmatter,
            body: parsed.body
        )

        return Artifact(
            id: id,
            agent: .copilot,
            kind: .subagent,
            scope: scope,
            name: name,
            location: location,
            contentHash: contentHash,
            enabled: true,
            loadMode: .frontmatterOnly,
            payload: .subagent(doc),
            diagnostics: parsed.diagnostics
        )
    }

    static func parsePromptCommandFile(
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
            agent: .copilot,
            kind: .command,
            scope: scope,
            path: identityPath
        )
        let contentHash = hashData(rawData)
        let parsed = FrontmatterParser.parse(text, location: location, redactSecrets: true)
        let frontmatter = parsed.frontmatter ?? [:]

        let name = nonEmptyString(frontmatter["name"]) ?? CopilotPathCatalog.defaultPromptCommandName(for: fileURL)
        let description = nonEmptyString(frontmatter["description"])
        let argumentHint = nonEmptyString(frontmatter["argument-hint"]) ?? nonEmptyString(frontmatter["argumentHint"])

        let doc = CommandDoc(
            name: name,
            description: description,
            argumentHint: argumentHint,
            body: parsed.body
        )

        return Artifact(
            id: id,
            agent: .copilot,
            kind: .command,
            scope: scope,
            name: name,
            location: location,
            contentHash: contentHash,
            enabled: true,
            loadMode: .onInvoke,
            payload: .command(doc),
            diagnostics: parsed.diagnostics
        )
    }

    // MARK: - Session Workspace Metadata

    /// Extracts `cwd` from `~/.copilot/session-state/<id>/workspace.yaml` (if present).
    static func parseWorkspaceCwd(in sessionDirectory: URL, env: AgentEnvironment) -> String? {
        let workspaceFile = CopilotPathCatalog.sessionWorkspaceFile(in: sessionDirectory)
        guard AdapterPathNormalizer.isEffectiveFile(workspaceFile, fileSystem: env.fileSystem),
            let data = try? env.fileSystem.contents(at: workspaceFile),
            let rawText = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        // Wrap in YAML frontmatter delimiters so FrontmatterParser (Yams) decodes arbitrary YAML scalars cleanly.
        let wrapped = "---\n\(rawText)\n---\n"
        let parsed = FrontmatterParser.parse(wrapped, redactSecrets: false)
        if let rawCwd = nonEmptyString(parsed.frontmatter?["cwd"])
            ?? nonEmptyString(parsed.frontmatter?["working_directory"])
        {
            return AdapterPathNormalizer.expandHomePrefix(rawCwd, in: env).path
        }
        return nil
    }

    // MARK: - Helpers

    private static func hashData(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            return ContentHasher.sha256NormalizedText(text)
        }
        return ContentHasher.sha256Hex(data)
    }

    static func nonEmptyString(_ value: JSONValue?) -> String? {
        guard case .string(let raw) = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func boolValue(_ value: JSONValue?) -> Bool? {
        switch value {
        case .bool(let flag):
            return flag
        default:
            return nil
        }
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
        return items.compactMap { nonEmptyString($0) }
    }

    static func extractGlobs(from value: JSONValue?) -> [String] {
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
