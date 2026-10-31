import BentoCore
import Foundation

/// Streamable HTTP MCP client supporting `application/json` and `text/event-stream` SSE framing,
/// `Mcp-Session-Id` propagation, pagination, and v1 OAuth (`401`/`403`) skipping (`PLAN.md` §6.4).
public struct StreamableHTTPMCPClient: Sendable {
    public let timeoutSeconds: TimeInterval
    private let urlSession: URLSession

    /// Creates a Streamable HTTP MCP client.
    public init(
        timeoutSeconds: TimeInterval = StdioMCPClient.defaultTimeoutSeconds,
        urlSession: URLSession? = nil
    ) {
        let clamped = min(max(0.1, timeoutSeconds), StdioMCPClient.maxTimeoutCeilingSeconds)
        self.timeoutSeconds = clamped
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = clamped
            config.timeoutIntervalForResource = clamped
            config.httpShouldSetCookies = false
            self.urlSession = URLSession(configuration: config)
        }
    }

    /// Probes a Streamable HTTP MCP endpoint (`initialize` -> `notifications/initialized` -> `tools/list`).
    internal func probe(
        serverName: String,
        urlString: String
    ) async throws -> MCPJSONRPC.HandshakeResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpointURL = URL(string: trimmed),
            let scheme = endpointURL.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            throw BentoMCPProbeError.invalidTransport(
                serverName: serverName,
                reason: "Invalid HTTP/SSE URL '\(urlString)'"
            )
        }

        // 1. initialize (id = 1)
        let initBody = try MCPJSONRPC.makeInitializeRequestData(id: 1)
        let (initObj, sessionID) = try await sendRPC(
            body: initBody,
            expectedID: 1,
            to: endpointURL,
            sessionID: nil,
            serverName: serverName
        )
        guard let initObj else {
            throw BentoMCPProbeError.protocolError(
                serverName: serverName,
                reason: "Empty HTTP response to initialize",
                stderr: ""
            )
        }
        let protocolVersion = try MCPJSONRPC.parseInitializeResult(
            from: initObj,
            serverName: serverName,
            stderr: ""
        )

        // 2. notifications/initialized
        let notifyBody = try MCPJSONRPC.makeInitializedNotificationData()
        _ = try await sendRPC(
            body: notifyBody,
            expectedID: nil,
            to: endpointURL,
            sessionID: sessionID,
            serverName: serverName
        )

        // 3. tools/list with pagination
        var allTools: [MCPToolSchema] = []
        var seenCursors: Set<String> = []
        var cursor: String?
        var requestID = 2

        for _ in 0..<MCPJSONRPC.maxPaginationPages {
            let listBody = try MCPJSONRPC.makeToolsListRequestData(id: requestID, cursor: cursor)
            let (listObj, _) = try await sendRPC(
                body: listBody,
                expectedID: requestID,
                to: endpointURL,
                sessionID: sessionID,
                serverName: serverName
            )
            guard let listObj else {
                throw BentoMCPProbeError.protocolError(
                    serverName: serverName,
                    reason: "Empty HTTP response to tools/list",
                    stderr: ""
                )
            }
            let page = try MCPJSONRPC.parseToolsListResult(
                from: listObj,
                serverName: serverName,
                stderr: ""
            )
            allTools.append(contentsOf: page.tools)

            guard let next = page.nextCursor, !next.isEmpty, !seenCursors.contains(next) else {
                break
            }
            seenCursors.insert(next)
            cursor = next
            requestID += 1
        }

        return MCPJSONRPC.HandshakeResult(
            protocolVersion: protocolVersion,
            tools: allTools
        )
    }

    // MARK: - Private Helpers

    private func sendRPC(
        body: Data,
        expectedID: Int?,
        to url: URL,
        sessionID: String?,
        serverName: String
    ) async throws -> (response: [String: JSONValue]?, sessionID: String?) {
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID, !sessionID.isEmpty {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = body

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await urlSession.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw BentoMCPProbeError.timedOut(
                serverName: serverName,
                seconds: timeoutSeconds,
                stderr: ""
            )
        } catch {
            throw BentoMCPProbeError.httpError(
                serverName: serverName,
                statusCode: 0,
                reason: error.localizedDescription
            )
        }

        guard let http = urlResponse as? HTTPURLResponse else {
            throw BentoMCPProbeError.httpError(
                serverName: serverName,
                statusCode: 0,
                reason: "Non-HTTP response"
            )
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw BentoMCPProbeError.oauthRequired(
                serverName: serverName,
                statusCode: http.statusCode
            )
        }

        guard (200...299).contains(http.statusCode) else {
            let snippet = String(decoding: data.prefix(512), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw BentoMCPProbeError.httpError(
                serverName: serverName,
                statusCode: http.statusCode,
                reason: snippet.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: http.statusCode) : snippet
            )
        }

        let returnedSessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id") ?? sessionID

        guard let expectedID else {
            return (nil, returnedSessionID)
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let rawText = String(decoding: data, as: UTF8.self)

        if contentType.contains("text/event-stream")
            || rawText.hasPrefix("event:")
            || rawText.hasPrefix("data:")
        {
            let parsed = try Self.extractJSONRPCFromSSE(
                rawText,
                expectedID: expectedID,
                serverName: serverName
            )
            return (parsed, returnedSessionID)
        }

        do {
            let obj = try MCPJSONRPC.decodeJSONObject(data)
            return (obj, returnedSessionID)
        } catch {
            throw BentoMCPProbeError.protocolError(
                serverName: serverName,
                reason: "Invalid JSON response body: \(error.localizedDescription)",
                stderr: ""
            )
        }
    }

    private static func extractJSONRPCFromSSE(
        _ streamText: String,
        expectedID: Int,
        serverName: String
    ) throws -> [String: JSONValue] {
        let normalized = streamText.replacingOccurrences(of: "\r\n", with: "\n")
        var currentDataLines: [String] = []
        var candidates: [[String: JSONValue]] = []

        func flushEvent() {
            guard !currentDataLines.isEmpty else { return }
            let joined = currentDataLines.joined(separator: "\n")
            currentDataLines.removeAll(keepingCapacity: true)
            if let obj = try? MCPJSONRPC.decodeJSONObject(Data(joined.utf8)) {
                candidates.append(obj)
            }
        }

        for line in normalized.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.isEmpty {
                flushEvent()
                continue
            }
            if line.hasPrefix("data:") {
                let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                currentDataLines.append(payload)
            }
        }
        flushEvent()

        if let matching = candidates.first(where: { MCPJSONRPC.matchesResponseID($0, expectedID: expectedID) }) {
            return matching
        }
        if let first = candidates.first {
            return first
        }
        throw BentoMCPProbeError.protocolError(
            serverName: serverName,
            reason: "No JSON-RPC data event found in SSE stream",
            stderr: ""
        )
    }
}
