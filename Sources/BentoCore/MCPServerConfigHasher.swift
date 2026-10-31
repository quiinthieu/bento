import Foundation

/// Computes collision-resistant SHA-256 digests identifying an MCP server's executable/endpoint
/// configuration for probe consent and schema caching (`PLAN.md` §4.2, §6.4, §7).
public enum MCPServerConfigHasher: Sendable {
    /// Computes the lowercase 64-character SHA-256 hex digest over `(transport, sortedUniqueEnvKeys)`.
    ///
    /// Mutating `command`, `args`, `url`, or `envKeys` always produces a distinct hash so prior consent
    /// and cached schemas are invalidated (`PLAN.md` §6.4).
    public static func hash(_ config: MCPServerConfig) -> String {
        var components: [String] = ["v1"]

        switch config.transport {
        case .stdio(let command, let args):
            components.append("stdio")
            components.append(lengthPrefixed(command))
            components.append("args:\(args.count)")
            for arg in args {
                components.append(lengthPrefixed(arg))
            }
        case .http(let url):
            components.append("http")
            components.append(lengthPrefixed(url))
        case .sse(let url):
            components.append("sse")
            components.append(lengthPrefixed(url))
        }

        let sortedEnvKeys = Array(Set(config.envKeys)).sorted()
        components.append("env:\(sortedEnvKeys.count)")
        for key in sortedEnvKeys {
            components.append(lengthPrefixed(key))
        }

        let canonical = components.joined(separator: "|")
        return ContentHasher.sha256Hex(Data(canonical.utf8))
    }

    private static func lengthPrefixed(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }
}
