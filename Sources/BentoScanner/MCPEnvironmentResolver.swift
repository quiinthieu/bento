import BentoCore
import BentoParsing
import Foundation

/// Resolves declared MCP server environment variable values ephemerally in memory from the agent's own
/// configuration file at consented probe time, without ever storing or logging secret values (`PLAN.md` §6.4, §7).
public enum MCPEnvironmentResolver: Sendable {
    /// Extracts values for keys declared in `config.envKeys` from `artifact.location` and `environment.env`.
    public static func resolveDeclaredEnvValues(
        for artifact: Artifact,
        config: MCPServerConfig,
        in environment: AgentEnvironment
    ) -> [String: String] {
        guard !config.envKeys.isEmpty else {
            return [:]
        }

        let allowedKeys = Set(config.envKeys)
        var resolved: [String: String] = [:]

        let fileURL = URL(fileURLWithPath: artifact.location.path)
        if let rawData = try? environment.fileSystem.contents(at: fileURL),
            let rootTree = parseRawObject(rawData, pathExtension: fileURL.pathExtension),
            let serverDict = walkKeyPath(artifact.location.keyPath ?? [], in: rootTree),
            case .object(let envDict) = serverDict["env"]
        {
            for (key, rawVal) in envDict where allowedKeys.contains(key) {
                if let strVal = scalarString(rawVal) {
                    resolved[key] = expandEnvPlaceholders(strVal, using: environment.env)
                }
            }
        }

        // Fill remaining declared pass-through keys (e.g. Codex `env_vars` / `bearer_token_env_var`).
        for key in config.envKeys where resolved[key] == nil {
            if let inherited = environment.env[key] {
                resolved[key] = inherited
            }
        }

        return resolved
    }

    private static func parseRawObject(_ data: Data, pathExtension: String) -> [String: JSONValue]? {
        if pathExtension.lowercased() == "toml" {
            return try? TOMLParser.parseObject(data, redactSecrets: false)
        }
        return try? JSONCParser.parseObject(data, redactSecrets: false)
    }

    private static func walkKeyPath(
        _ keyPath: [String],
        in root: [String: JSONValue]
    ) -> [String: JSONValue]? {
        var current = root
        for segment in keyPath {
            guard case .object(let next) = current[segment] else {
                return nil
            }
            current = next
        }
        return current
    }

    private static func scalarString(_ value: JSONValue) -> String? {
        switch value {
        case .string(let s):
            return s
        case .int(let i):
            return String(i)
        case .double(let d):
            return String(d)
        case .bool(let b):
            return b ? "true" : "false"
        case .null, .array, .object:
            return nil
        }
    }

    private static func expandEnvPlaceholders(_ raw: String, using env: [String: String]) -> String {
        guard raw.contains("${") else {
            return raw
        }
        var output = ""
        var cursor = raw.startIndex
        while cursor < raw.endIndex {
            if raw[cursor...].hasPrefix("${"),
                let closeIdx = raw[cursor...].firstIndex(of: "}")
            {
                let exprStart = raw.index(cursor, offsetBy: 2)
                let expr = String(raw[exprStart..<closeIdx])
                if let fallbackRange = expr.range(of: ":-") {
                    let varName = String(expr[..<fallbackRange.lowerBound])
                    let defaultVal = String(expr[fallbackRange.upperBound...])
                    if let val = env[varName], !val.isEmpty {
                        output.append(val)
                    } else {
                        output.append(defaultVal)
                    }
                } else {
                    output.append(env[expr] ?? "")
                }
                cursor = raw.index(after: closeIdx)
            } else {
                output.append(raw[cursor])
                cursor = raw.index(after: cursor)
            }
        }
        return output
    }
}
