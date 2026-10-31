import Foundation

/// Errors thrown during explicit-consent MCP server probing (`PLAN.md` §6.4, §7, §11 T10).
public enum BentoMCPProbeError: Error, LocalizedError, Sendable, Equatable, CustomStringConvertible {
    /// Probing was attempted without explicit user consent for `serverConfigHash`.
    case consentRequired(serverName: String, serverConfigHash: String)
    /// The server configuration specifies an empty or malformed command or URL.
    case invalidTransport(serverName: String, reason: String)
    /// The server exceeded the configured wall-clock timeout and was terminated.
    case timedOut(serverName: String, seconds: Double, stderr: String)
    /// Launching the stdio child process failed.
    case processLaunchFailed(serverName: String, reason: String)
    /// The stdio child process exited unexpectedly or crashed before completing `tools/list`.
    case processCrashed(serverName: String, exitCode: Int32, stderr: String)
    /// The server returned malformed JSON-RPC or an error response.
    case protocolError(serverName: String, reason: String, stderr: String)
    /// The HTTP/SSE server requires OAuth/Bearer authentication (`401`/`403`), skipped in v1 (`PLAN.md` §6.4).
    case oauthRequired(serverName: String, statusCode: Int)
    /// The HTTP/SSE endpoint failed with a non-2xx HTTP status or transport failure.
    case httpError(serverName: String, statusCode: Int, reason: String)

    public var description: String {
        switch self {
        case .consentRequired(let serverName, let hash):
            return "Explicit consent is required before probing MCP server '\(serverName)' (hash: \(hash.prefix(12)))."
        case .invalidTransport(let serverName, let reason):
            return "MCP server '\(serverName)' has an invalid transport: \(reason)"
        case .timedOut(let serverName, let seconds, let stderr):
            let suffix = stderr.isEmpty ? "" : " | stderr: \(stderr)"
            return String(format: "MCP server '%@' timed out after %.1fs%@", serverName, seconds, suffix)
        case .processLaunchFailed(let serverName, let reason):
            return "Failed to launch MCP server '\(serverName)': \(reason)"
        case .processCrashed(let serverName, let exitCode, let stderr):
            let suffix = stderr.isEmpty ? "" : " | stderr: \(stderr)"
            return "MCP server '\(serverName)' exited with status \(exitCode)\(suffix)"
        case .protocolError(let serverName, let reason, let stderr):
            let suffix = stderr.isEmpty ? "" : " | stderr: \(stderr)"
            return "MCP protocol error from '\(serverName)': \(reason)\(suffix)"
        case .oauthRequired(let serverName, let statusCode):
            return "MCP server '\(serverName)' requires authentication (HTTP \(statusCode)); skipped in v1."
        case .httpError(let serverName, let statusCode, let reason):
            return "MCP HTTP server '\(serverName)' failed (HTTP \(statusCode)): \(reason)"
        }
    }

    public var errorDescription: String? { description }
}
