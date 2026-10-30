import BentoCore
import Foundation

/// Parse-time secret redactor enforcing `PLAN.md` §7 privacy guarantees.
public enum SecretRedactor {
    /// Replacement sentinel substituted for redacted secret values (`PLAN.md` §7).
    public static let marker = "«redacted»"

    private static let sensitiveKeyFragments: [String] = [
        "key",
        "token",
        "secret",
        "password"
    ]

    private static let exactSensitiveKeys: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie"
    ]

    private static let secretMapKeys: Set<String> = [
        "env",
        "headers",
        "http_headers",
        "httpheaders",
        "env_http_headers"
    ]

    private static let sensitiveCLIFlags: Set<String> = [
        "-h",
        "--header",
        "--api-key",
        "--apikey",
        "--token",
        "--access-token",
        "--auth-token",
        "--secret",
        "--client-secret",
        "--password"
    ]

    /// Returns whether a key name matches `/(key|token|secret|password)/i` or `Authorization`.
    public static func isSensitiveKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        if exactSensitiveKeys.contains(lower) {
            return true
        }
        return sensitiveKeyFragments.contains { lower.contains($0) }
    }

    /// Returns whether a container key holds arbitrary user-named secret values (`env`, `headers`, etc.).
    public static func isSecretMapKey(_ key: String) -> Bool {
        secretMapKeys.contains(key.lowercased())
    }

    /// Redacts sensitive keys, container maps, and secret-shaped string values in a `JSONValue` tree.
    public static func redact(_ value: JSONValue) -> JSONValue {
        switch value {
        case .null, .bool, .int, .double:
            return value
        case .string(let text):
            return .string(redactStringValue(text))
        case .array(let elements):
            return .array(redactArray(elements))
        case .object(let dictionary):
            return .object(redact(dictionary))
        }
    }

    /// Redacts a top-level dictionary of `JSONValue` entries.
    public static func redact(_ dictionary: [String: JSONValue]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        result.reserveCapacity(dictionary.count)

        for (key, value) in dictionary {
            if isSecretMapKey(key) {
                result[key] = redactSecretContainer(value)
            } else if isSensitiveKey(key) {
                result[key] = forceRedactSubtree(value)
            } else {
                result[key] = redact(value)
            }
        }
        return result
    }

    /// Redacts a `SettingsDoc` tree.
    public static func redact(_ settings: SettingsDoc) -> SettingsDoc {
        SettingsDoc(format: settings.format, tree: redact(settings.tree))
    }

    /// Redacts an `ArtifactPayload` before persistence or JSON serialization.
    public static func redact(_ payload: ArtifactPayload) -> ArtifactPayload {
        switch payload {
        case .settings(let doc):
            return .settings(redact(doc))
        case .rules(var doc):
            if let frontmatter = doc.frontmatter {
                doc.frontmatter = redact(frontmatter)
            }
            return .rules(doc)
        case .skill(var doc):
            doc.frontmatter = redact(doc.frontmatter)
            return .skill(doc)
        case .mcpServer(var config):
            config.transport = redactTransport(config.transport)
            return .mcpServer(config)
        case .subagent, .command, .hook, .plugin, .other:
            return payload
        }
    }

    /// Extracts an `MCPServerConfig` from a raw JSON/TOML server dictionary, storing `envKeys` only.
    public static func extractMCPServerConfig(from rawObject: [String: JSONValue]) -> MCPServerConfig? {
        let envKeys: [String]
        if case .object(let envMap) = rawObject["env"] {
            envKeys = envMap.keys.sorted()
        } else {
            envKeys = []
        }

        let disabled: Bool
        if case .bool(let isDisabled) = rawObject["disabled"] {
            disabled = isDisabled
        } else if case .bool(let isEnabled) = rawObject["enabled"] {
            disabled = !isEnabled
        } else {
            disabled = false
        }

        let allowedTools =
            stringArray(from: rawObject["allowedTools"])
            ?? stringArray(from: rawObject["enabled_tools"])
            ?? stringArray(from: rawObject["includeTools"])

        let disabledTools =
            stringArray(from: rawObject["disabledTools"])
            ?? stringArray(from: rawObject["disabled_tools"])
            ?? stringArray(from: rawObject["excludeTools"])

        if case .string(let command) = rawObject["command"] {
            let rawArgs =
                rawObject["args"].flatMap { value -> [JSONValue]? in
                    if case .array(let list) = value { return list }
                    return nil
                } ?? []
            let redactedArgValues = redactArray(rawArgs)
            let args: [String] = redactedArgValues.compactMap { item in
                if case .string(let arg) = item { return arg }
                return nil
            }
            return MCPServerConfig(
                transport: .stdio(command: redactStringValue(command), args: args),
                envKeys: envKeys,
                disabled: disabled,
                allowedTools: allowedTools,
                disabledTools: disabledTools
            )
        }

        let urlCandidate = rawObject["url"] ?? rawObject["httpUrl"]
        if case .string(let rawURL) = urlCandidate {
            let sanitizedURL = redactStringValue(rawURL)
            let explicitType: String?
            if case .string(let typeStr) = rawObject["type"] ?? rawObject["transport"] {
                explicitType = typeStr.lowercased()
            } else {
                explicitType = nil
            }
            let transport: MCPServerConfig.Transport =
                explicitType == "sse" ? .sse(url: sanitizedURL) : .http(url: sanitizedURL)
            return MCPServerConfig(
                transport: transport,
                envKeys: envKeys,
                disabled: disabled,
                allowedTools: allowedTools,
                disabledTools: disabledTools
            )
        }

        return nil
    }

    private static func redactTransport(_ transport: MCPServerConfig.Transport) -> MCPServerConfig.Transport {
        switch transport {
        case .stdio(let command, let args):
            let jsonArgs = args.map(JSONValue.string)
            let redactedArgs = redactArray(jsonArgs).compactMap { item -> String? in
                if case .string(let text) = item { return text }
                return nil
            }
            return .stdio(command: redactStringValue(command), args: redactedArgs)
        case .http(let url):
            return .http(url: redactStringValue(url))
        case .sse(let url):
            return .sse(url: redactStringValue(url))
        }
    }

    private static func redactSecretContainer(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let map):
            var result: [String: JSONValue] = [:]
            result.reserveCapacity(map.count)
            for (entryKey, entryVal) in map {
                result[entryKey] = forceRedactSubtree(entryVal)
            }
            return .object(result)
        case .array(let list):
            return .array(list.map(forceRedactSubtree))
        case .null:
            return .null
        case .bool, .int, .double, .string:
            return .string(marker)
        }
    }

    private static func forceRedactSubtree(_ value: JSONValue) -> JSONValue {
        switch value {
        case .null:
            return .null
        case .array(let list):
            return .array(list.map(forceRedactSubtree))
        case .object(let map):
            var result: [String: JSONValue] = [:]
            result.reserveCapacity(map.count)
            for (k, v) in map {
                result[k] = forceRedactSubtree(v)
            }
            return .object(result)
        case .bool, .int, .double, .string:
            return .string(marker)
        }
    }

    private static func redactArray(_ elements: [JSONValue]) -> [JSONValue] {
        var output: [JSONValue] = []
        output.reserveCapacity(elements.count)
        var redactNext = false

        for element in elements {
            if redactNext {
                output.append(.string(marker))
                redactNext = false
                continue
            }

            if case .string(let text) = element {
                let lower = text.trimmingCharacters(in: .whitespaces).lowercased()
                if sensitiveCLIFlags.contains(lower) {
                    output.append(.string(text))
                    redactNext = true
                    continue
                }
            }

            output.append(redact(element))
        }
        return output
    }

    private static func redactStringValue(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("bearer ")
            || lower.hasPrefix("basic ")
            || lower.hasPrefix("authorization:")
            || lower.hasPrefix("proxy-authorization:")
        {
            return marker
        }

        if trimmed.hasPrefix("-"), let eqIndex = trimmed.firstIndex(of: "=") {
            let flagName = String(trimmed[..<eqIndex]).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if isSensitiveKey(flagName) || flagName.lowercased() == "header" {
                let prefix = String(trimmed[...eqIndex])
                return prefix + marker
            }
        }

        if matchesKnownTokenPrefix(trimmed) {
            return marker
        }

        if trimmed.contains("://") {
            return sanitizeURLString(text)
        }

        return text
    }

    private static func matchesKnownTokenPrefix(_ text: String) -> Bool {
        let prefixes: [(prefix: String, minLength: Int)] = [
            ("sk-ant-", 20),
            ("sk-proj-", 20),
            ("sk-", 24),
            ("ghp_", 24),
            ("gho_", 24),
            ("ghu_", 24),
            ("ghs_", 24),
            ("ghr_", 24),
            ("github_pat_", 24),
            ("AIza", 32),
            ("glpat-", 20),
            ("xoxb-", 16),
            ("xoxp-", 16),
            ("xoxa-", 16),
            ("xoxr-", 16),
            ("xoxs-", 16)
        ]

        for entry in prefixes {
            if let range = text.range(of: entry.prefix) {
                let tail = text[range.lowerBound...]
                let tokenChars = tail.prefix { char in
                    char.isLetter || char.isNumber || char == "_" || char == "-"
                }
                if tokenChars.count >= entry.minLength {
                    return true
                }
            }
        }
        return false
    }

    private static func sanitizeURLString(_ rawURL: String) -> String {
        var result = rawURL

        if let schemeRange = result.range(of: "://") {
            let afterScheme = result[schemeRange.upperBound...]
            let authorityEnd =
                afterScheme.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? afterScheme.endIndex
            let authority = afterScheme[..<authorityEnd]
            if let atIndex = authority.lastIndex(of: "@") {
                result.replaceSubrange(schemeRange.upperBound..<atIndex, with: marker)
            }
        }

        if let questionIndex = result.firstIndex(of: "?") {
            let fragmentIndex = result[questionIndex...].firstIndex(of: "#") ?? result.endIndex
            let queryStart = result.index(after: questionIndex)
            let rawQuery = String(result[queryStart..<fragmentIndex])
            var changed = false
            let rewrittenParts: [String] = rawQuery.split(
                separator: "&",
                omittingEmptySubsequences: false
            ).map { part in
                guard let eq = part.firstIndex(of: "=") else {
                    return String(part)
                }
                let paramName = String(part[..<eq]).removingPercentEncoding ?? String(part[..<eq])
                if isSensitiveKey(paramName) {
                    changed = true
                    return String(part[...eq]) + marker
                }
                return String(part)
            }
            if changed {
                result.replaceSubrange(
                    queryStart..<fragmentIndex,
                    with: rewrittenParts.joined(separator: "&")
                )
            }
        }

        return result
    }

    private static func stringArray(from value: JSONValue?) -> [String]? {
        guard case .array(let items) = value else { return nil }
        return items.compactMap { item in
            if case .string(let text) = item { return text }
            return nil
        }
    }
}
