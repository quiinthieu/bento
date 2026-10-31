import BentoCore
import BentoParsing
import Foundation

/// Streaming JSONL rollout log decoder for OpenAI Codex CLI (`PLAN.md` §5.2, §6.2).
///
/// Decodes `session_meta`, `turn_context`, `event_msg` (`token_count` with duplicate consecutive
/// `total_token_usage` suppression), and `response_item` (`function_call`, `custom_tool_call`,
/// `mcp_tool_call`), hitting well over 150 MB/s on plain JSONL corpora.
public struct CodexLogDecoder: LogDecoder, Sendable {
    private struct TokenTriple: Codable, Equatable {
        var input: Int
        var cached: Int
        var output: Int
    }

    private struct ResumeState: Codable {
        var activeSessionID: String?
        var activeCwd: String?
        var activeModel: String?
        var observedModels: [String: String]
        var emittedSessionStarts: Set<String>
        var seenCallIDs: Set<String>
        var turnIndexBySession: [String: Int]
        var lastTotalUsageBySession: [String: TokenTriple]
    }

    private enum FastDecodeAction {
        case skip
        case invalid
        case event(UsageEvent, incrementTurn: Bool)
        case fallback
    }

    private var activeSessionID: String?
    private var activeSessionStarted = false
    private var activeTurnIndex = 0
    private var activeCwd: String?
    private var activeModel: String?
    private var observedModels: [String: String] = [:]
    private var emittedSessionStarts: Set<String> = []
    private var seenCallIDs: Set<String> = []
    private var turnIndexBySession: [String: Int] = [:]
    private var lastTotalUsageBySession: [String: TokenTriple] = [:]
    private var errors = 0

    /// Creates a Codex CLI log decoder.
    public init() {}

    public var errorCount: Int {
        errors
    }

    public var observedModelsBySession: [String: String] {
        observedModels
    }

    public func exportResumeState() -> Data? {
        var snapshotTurns = turnIndexBySession
        if let id = activeSessionID {
            snapshotTurns[id] = activeTurnIndex
        }
        let state = ResumeState(
            activeSessionID: activeSessionID,
            activeCwd: activeCwd,
            activeModel: activeModel,
            observedModels: observedModels,
            emittedSessionStarts: emittedSessionStarts,
            seenCallIDs: seenCallIDs,
            turnIndexBySession: snapshotTurns,
            lastTotalUsageBySession: lastTotalUsageBySession
        )
        return try? JSONEncoder().encode(state)
    }

    public mutating func restoreResumeState(_ data: Data) {
        guard let state = try? JSONDecoder().decode(ResumeState.self, from: data) else {
            return
        }
        activeSessionID = state.activeSessionID
        activeCwd = state.activeCwd
        activeModel = state.activeModel
        observedModels = state.observedModels
        emittedSessionStarts = state.emittedSessionStarts
        seenCallIDs = state.seenCallIDs
        turnIndexBySession = state.turnIndexBySession
        lastTotalUsageBySession = state.lastTotalUsageBySession
        if let id = activeSessionID {
            activeSessionStarted = emittedSessionStarts.contains(id)
            activeTurnIndex = turnIndexBySession[id, default: 0]
        } else {
            activeSessionStarted = false
            activeTurnIndex = 0
        }
    }

    public mutating func decode(line: Data, source: LogSource) -> [UsageEvent] {
        if line.isEmpty {
            return []
        }

        let currentSession = activeSessionID
        let currentStarted = activeSessionStarted
        let currentTurn = activeTurnIndex
        let resolvedCwd = activeCwd ?? source.inferredCwd

        let action: FastDecodeAction = line.withUnsafeBytes { rawBuffer in
            let buf = rawBuffer.bindMemory(to: UInt8.self)
            switch FastLogJSON.inspectObjectFraming(in: buf) {
            case .empty:
                return .skip
            case .invalid:
                return .invalid
            case .object:
                break
            }

            let hasTokenCount = FastLogJSON.containsASCII("\"token_count\"", in: buf)
            let hasAnyCall = !hasTokenCount && FastLogJSON.containsASCII("_call\"", in: buf)
            if !hasTokenCount && !hasAnyCall {
                let hasMeta = FastLogJSON.containsASCII("\"session_meta\"", in: buf)
                let hasContext = !hasMeta && FastLogJSON.containsASCII("\"turn_context\"", in: buf)
                if !hasMeta && !hasContext {
                    return .skip
                }
                return .fallback
            }

            // Fast zero-dictionary path for simple `token_count` lines without `total_token_usage`.
            if hasTokenCount,
                currentStarted,
                let sessionID = currentSession,
                !FastLogJSON.containsASCII("\"total_token_usage\"", in: buf),
                let lastUsageOffset = FastLogJSON.offsetOfASCII("\"last_token_usage\"", in: buf),
                let timestamp = FastLogJSON.extractTimestamp(afterKeyPattern: "\"timestamp\":", in: buf),
                let input = FastLogJSON.extractNonNegativeInt(
                    afterKeyPattern: "\"input_tokens\":",
                    in: buf,
                    from: lastUsageOffset
                ),
                let output = FastLogJSON.extractNonNegativeInt(
                    afterKeyPattern: "\"output_tokens\":",
                    in: buf,
                    from: lastUsageOffset
                )
            {
                let cached = FastLogJSON.extractNonNegativeInt(
                    afterKeyPattern: "\"cached_input_tokens\":",
                    in: buf,
                    from: lastUsageOffset
                )
                return .event(
                    UsageEvent(
                        agent: .codex,
                        sessionID: sessionID,
                        timestamp: timestamp,
                        cwd: resolvedCwd,
                        kind: .tokenUsage(
                            input: input,
                            cachedInput: cached,
                            output: output,
                            turnIndex: currentTurn
                        )
                    ),
                    incrementTurn: true
                )
            }

            // Fast zero-dictionary path for simple built-in `function_call` lines without `call_id` or special wrappers.
            if hasAnyCall,
                currentStarted,
                let sessionID = currentSession,
                FastLogJSON.containsASCII("\"function_call\"", in: buf),
                !FastLogJSON.containsASCII("\"call_id\"", in: buf),
                FastLogJSON.containsASCII("\"type\":\"response_item\"", in: buf),
                let timestamp = FastLogJSON.extractTimestamp(afterKeyPattern: "\"timestamp\":", in: buf),
                let toolName = FastLogJSON.extractSimpleString(afterKeyPattern: "\"name\":", in: buf),
                !toolName.hasPrefix("mcp__"),
                toolName != "use_skill",
                toolName != "activate_skill",
                toolName != "skill",
                toolName != "spawn_agent",
                toolName != "delegate_to_agent"
            {
                return .event(
                    UsageEvent(
                        agent: .codex,
                        sessionID: sessionID,
                        timestamp: timestamp,
                        cwd: resolvedCwd,
                        kind: .builtinToolCalled(name: toolName)
                    ),
                    incrementTurn: false
                )
            }

            return .fallback
        }

        switch action {
        case .skip:
            return []
        case .invalid:
            errors += 1
            return []
        case .event(let event, let incrementTurn):
            if incrementTurn {
                activeTurnIndex += 1
            }
            return [event]
        case .fallback:
            break
        }

        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            errors += 1
            return []
        }

        let recordType = (obj["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let payload = obj["payload"] as? [String: Any]
        let timestamp = FastLogJSON.parseTimestamp(obj["timestamp"])

        if let topCwd = Self.nonEmptyString(obj["cwd"]) {
            activeCwd = source.normalizeLoggedCwd(topCwd)
        }

        var emitted: [UsageEvent] = []

        func currentSessionID() -> String {
            activeSessionID ?? Self.fallbackSessionID(for: source.url)
        }

        func ensureSessionStarted(sessionID: String) {
            if emittedSessionStarts.insert(sessionID).inserted {
                if sessionID == activeSessionID {
                    activeSessionStarted = true
                }
                emitted.append(
                    UsageEvent(
                        agent: .codex,
                        sessionID: sessionID,
                        timestamp: timestamp,
                        cwd: activeCwd ?? source.inferredCwd,
                        kind: .sessionStart(model: activeModel)
                    )
                )
            }
        }

        switch recordType {
        case "session_meta":
            if let id = Self.nonEmptyString(payload?["id"]) ?? Self.nonEmptyString(payload?["session_id"]) {
                if let prev = activeSessionID, prev != id {
                    turnIndexBySession[prev] = activeTurnIndex
                }
                if activeSessionID != id {
                    activeSessionID = id
                    activeSessionStarted = emittedSessionStarts.contains(id)
                    activeTurnIndex = turnIndexBySession[id, default: 0]
                }
            }
            if let rawCwd = Self.nonEmptyString(payload?["cwd"]) {
                activeCwd = source.normalizeLoggedCwd(rawCwd)
            } else if activeCwd == nil {
                activeCwd = source.inferredCwd
            }
            let sessionID = currentSessionID()
            if let model = Self.nonEmptyString(payload?["model"]) ?? Self.nonEmptyString(obj["model"]) {
                activeModel = model
                observedModels[sessionID] = model
            }
            ensureSessionStarted(sessionID: sessionID)

        case "turn_context":
            if let rawCwd = Self.nonEmptyString(payload?["cwd"]) {
                activeCwd = source.normalizeLoggedCwd(rawCwd)
            }
            let sessionID = currentSessionID()
            if let model = Self.nonEmptyString(payload?["model"]) {
                activeModel = model
                observedModels[sessionID] = model
            }
            ensureSessionStarted(sessionID: sessionID)

        case "event_msg":
            guard (payload?["type"] as? String) == "token_count" else { break }
            guard let info = payload?["info"] as? [String: Any] else { break }
            let sessionID = currentSessionID()

            if let totalDict = info["total_token_usage"] as? [String: Any],
                let totalInput = FastLogJSON.intValue(totalDict["input_tokens"])
            {
                let triple = TokenTriple(
                    input: totalInput,
                    cached: FastLogJSON.intValue(totalDict["cached_input_tokens"]) ?? 0,
                    output: FastLogJSON.intValue(totalDict["output_tokens"]) ?? 0
                )
                if lastTotalUsageBySession[sessionID] == triple {
                    break
                }
                lastTotalUsageBySession[sessionID] = triple
            }

            let usageDict =
                (info["last_token_usage"] as? [String: Any])
                ?? (info["total_token_usage"] as? [String: Any])
            guard
                let usageDict,
                let input = FastLogJSON.intValue(usageDict["input_tokens"])
            else {
                break
            }
            let cached =
                FastLogJSON.intValue(usageDict["cached_input_tokens"])
                ?? FastLogJSON.intValue(usageDict["cache_read_input_tokens"])
            let output = FastLogJSON.intValue(usageDict["output_tokens"]) ?? 0

            ensureSessionStarted(sessionID: sessionID)
            let turnIndex: Int
            if sessionID == activeSessionID {
                turnIndex = activeTurnIndex
                activeTurnIndex += 1
                turnIndexBySession[sessionID] = activeTurnIndex
            } else {
                turnIndex = turnIndexBySession[sessionID, default: 0]
                turnIndexBySession[sessionID] = turnIndex + 1
            }
            emitted.append(
                UsageEvent(
                    agent: .codex,
                    sessionID: sessionID,
                    timestamp: timestamp,
                    cwd: activeCwd ?? source.inferredCwd,
                    kind: .tokenUsage(
                        input: input,
                        cachedInput: cached,
                        output: output,
                        turnIndex: turnIndex
                    )
                )
            )

        case "response_item":
            let itemType = (payload?["type"] as? String) ?? ""
            let sessionID = currentSessionID()

            switch itemType {
            case "function_call", "custom_tool_call":
                if let callID = Self.nonEmptyString(payload?["call_id"]) ?? Self.nonEmptyString(payload?["id"]) {
                    let scoped = "\(sessionID)|\(callID)"
                    guard seenCallIDs.insert(scoped).inserted else { break }
                }
                guard let name = Self.nonEmptyString(payload?["name"]) else { break }
                ensureSessionStarted(sessionID: sessionID)
                let args = FastLogJSON.dictionaryArguments(payload?["arguments"] ?? payload?["input"])
                if let kind = Self.classifyFunctionCall(name: name, arguments: args) {
                    emitted.append(
                        UsageEvent(
                            agent: .codex,
                            sessionID: sessionID,
                            timestamp: timestamp,
                            cwd: activeCwd ?? source.inferredCwd,
                            kind: kind
                        )
                    )
                }

            case "mcp_tool_call":
                if let callID = Self.nonEmptyString(payload?["call_id"]) ?? Self.nonEmptyString(payload?["id"]) {
                    let scoped = "\(sessionID)|\(callID)"
                    guard seenCallIDs.insert(scoped).inserted else { break }
                }
                if let server = Self.nonEmptyString(payload?["server"]),
                    let tool = Self.nonEmptyString(payload?["tool"]) ?? Self.nonEmptyString(payload?["name"])
                {
                    ensureSessionStarted(sessionID: sessionID)
                    emitted.append(
                        UsageEvent(
                            agent: .codex,
                            sessionID: sessionID,
                            timestamp: timestamp,
                            cwd: activeCwd ?? source.inferredCwd,
                            kind: .mcpToolCalled(server: server, tool: tool)
                        )
                    )
                }

            default:
                break
            }

        default:
            break
        }

        return emitted
    }

    // MARK: - Helpers

    private static func classifyFunctionCall(name: String, arguments: [String: Any]?) -> UsageEvent.Kind? {
        if let mcp = FastLogJSON.parseMCPToolName(name) {
            return .mcpToolCalled(server: mcp.server, tool: mcp.tool)
        }
        switch name {
        case "use_skill", "activate_skill", "skill":
            if let skill = nonEmptyString(arguments?["skill"]) ?? nonEmptyString(arguments?["name"]) {
                return .skillInvoked(name: skill)
            }
            return .builtinToolCalled(name: name)
        case "spawn_agent", "delegate_to_agent":
            let subagent =
                nonEmptyString(arguments?["agent"])
                ?? nonEmptyString(arguments?["agent_type"])
                ?? nonEmptyString(arguments?["role"])
                ?? nonEmptyString(arguments?["name"])
                ?? name
            return .subagentInvoked(name: subagent)
        default:
            return .builtinToolCalled(name: name)
        }
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let str = raw as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func fallbackSessionID(for url: URL) -> String {
        var name = url.lastPathComponent
        if name.lowercased().hasSuffix(".zst") {
            name = String(name.dropLast(4))
        }
        if name.lowercased().hasSuffix(".jsonl") {
            name = String(name.dropLast(6))
        }
        return name.isEmpty ? "codex-session" : name
    }
}
