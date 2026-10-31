import BentoCore
import BentoParsing
import Foundation

/// Streaming JSONL event log decoder for GitHub Copilot CLI (`PLAN.md` §5.2, §6.2).
///
/// Decodes `session.start`, `session.model_change`, `tool.execution_start` (built-in tools,
/// skills, subagents, and MCP tools via `mcpServerName`/`mcpToolName` or `mcp__*`), and
/// `assistant.usage`, preserving zero prompt or response text.
public struct CopilotLogDecoder: LogDecoder, Sendable {
    private struct ResumeState: Codable {
        var activeSessionID: String?
        var activeCwd: String?
        var activeModel: String?
        var observedModels: [String: String]
        var emittedSessionStarts: Set<String>
        var seenToolCallIDs: Set<String>
        var seenUsageEventIDs: Set<String>
        var turnIndexBySession: [String: Int]
    }

    private var activeSessionID: String?
    private var activeCwd: String?
    private var activeModel: String?
    private var observedModels: [String: String] = [:]
    private var emittedSessionStarts: Set<String> = []
    private var seenToolCallIDs: Set<String> = []
    private var seenUsageEventIDs: Set<String> = []
    private var turnIndexBySession: [String: Int] = [:]
    private var errors = 0

    /// Creates a Copilot CLI log decoder.
    public init() {}

    public var errorCount: Int {
        errors
    }

    public var observedModelsBySession: [String: String] {
        observedModels
    }

    public func exportResumeState() -> Data? {
        let state = ResumeState(
            activeSessionID: activeSessionID,
            activeCwd: activeCwd,
            activeModel: activeModel,
            observedModels: observedModels,
            emittedSessionStarts: emittedSessionStarts,
            seenToolCallIDs: seenToolCallIDs,
            seenUsageEventIDs: seenUsageEventIDs,
            turnIndexBySession: turnIndexBySession
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
        seenToolCallIDs = state.seenToolCallIDs
        seenUsageEventIDs = state.seenUsageEventIDs
        turnIndexBySession = state.turnIndexBySession
    }

    public mutating func decode(line: Data, source: LogSource) -> [UsageEvent] {
        switch FastLogJSON.inspectObjectFraming(in: line) {
        case .empty:
            return []
        case .invalid:
            errors += 1
            return []
        case .object:
            break
        }

        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            errors += 1
            return []
        }

        let recordType = (obj["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let dataDict = obj["data"] as? [String: Any]
        let contextDict = (dataDict?["context"] as? [String: Any]) ?? (obj["context"] as? [String: Any])

        if let rawSessionID =
            Self.nonEmptyString(obj["sessionId"])
            ?? Self.nonEmptyString(dataDict?["sessionId"])
            ?? Self.nonEmptyString(obj["session_id"])
        {
            activeSessionID = rawSessionID
        }
        let sessionID = activeSessionID ?? Self.fallbackSessionID(for: source.url)

        if let rawCwd =
            Self.nonEmptyString(obj["cwd"])
            ?? Self.nonEmptyString(dataDict?["cwd"])
            ?? Self.nonEmptyString(contextDict?["cwd"])
        {
            activeCwd = source.normalizeLoggedCwd(rawCwd)
        } else if activeCwd == nil {
            activeCwd = source.inferredCwd
        }
        let cwd = activeCwd

        let timestamp = FastLogJSON.parseTimestamp(obj["timestamp"])
        var emitted: [UsageEvent] = []

        func ensureSessionStarted() {
            if emittedSessionStarts.insert(sessionID).inserted {
                emitted.append(
                    UsageEvent(
                        agent: .copilot,
                        sessionID: sessionID,
                        timestamp: timestamp,
                        cwd: cwd,
                        kind: .sessionStart(model: activeModel)
                    )
                )
            }
        }

        switch recordType {
        case "session.start":
            if let model =
                Self.nonEmptyString(dataDict?["selectedModel"])
                ?? Self.nonEmptyString(dataDict?["model"])
                ?? Self.nonEmptyString(obj["model"])
            {
                activeModel = model
                observedModels[sessionID] = model
            }
            ensureSessionStarted()

        case "session.model_change", "model.change":
            if let model =
                Self.nonEmptyString(dataDict?["newModel"])
                ?? Self.nonEmptyString(dataDict?["selectedModel"])
                ?? Self.nonEmptyString(dataDict?["model"])
            {
                activeModel = model
                observedModels[sessionID] = model
            }

        case "tool.execution_start":
            let callID = Self.nonEmptyString(dataDict?["toolCallId"]) ?? Self.nonEmptyString(obj["id"])
            if let callID {
                guard seenToolCallIDs.insert("\(sessionID)|\(callID)").inserted else {
                    break
                }
            }
            ensureSessionStarted()
            if let kind = Self.classifyToolStart(data: dataDict) {
                emitted.append(
                    UsageEvent(
                        agent: .copilot,
                        sessionID: sessionID,
                        timestamp: timestamp,
                        cwd: cwd,
                        kind: kind
                    )
                )
            }

        case "assistant.usage":
            if let eventID = Self.nonEmptyString(obj["id"]) {
                guard seenUsageEventIDs.insert("\(sessionID)|\(eventID)").inserted else {
                    break
                }
            }
            if let model = Self.nonEmptyString(dataDict?["model"]) ?? Self.nonEmptyString(obj["model"]) {
                activeModel = model
                observedModels[sessionID] = model
            }
            guard
                let input =
                    FastLogJSON.intValue(dataDict?["inputTokens"])
                    ?? FastLogJSON.intValue(dataDict?["input_tokens"])
            else {
                break
            }
            let cached =
                FastLogJSON.intValue(dataDict?["cacheReadTokens"])
                ?? FastLogJSON.intValue(dataDict?["cachedInputTokens"])
                ?? FastLogJSON.intValue(dataDict?["cache_read_input_tokens"])
            let output =
                FastLogJSON.intValue(dataDict?["outputTokens"])
                ?? FastLogJSON.intValue(dataDict?["output_tokens"])
                ?? 0

            ensureSessionStarted()
            let turnIndex = turnIndexBySession[sessionID, default: 0]
            turnIndexBySession[sessionID] = turnIndex + 1
            emitted.append(
                UsageEvent(
                    agent: .copilot,
                    sessionID: sessionID,
                    timestamp: timestamp,
                    cwd: cwd,
                    kind: .tokenUsage(
                        input: input,
                        cachedInput: cached,
                        output: output,
                        turnIndex: turnIndex
                    )
                )
            )

        default:
            break
        }

        return emitted
    }

    // MARK: - Helpers

    private static func classifyToolStart(data: [String: Any]?) -> UsageEvent.Kind? {
        guard let data else { return nil }
        if let mcpServer = nonEmptyString(data["mcpServerName"]) {
            let mcpTool =
                nonEmptyString(data["mcpToolName"])
                ?? nonEmptyString(data["toolName"])
                ?? "unknown"
            return .mcpToolCalled(server: mcpServer, tool: mcpTool)
        }

        guard let toolName = nonEmptyString(data["toolName"]) ?? nonEmptyString(data["name"]) else {
            return nil
        }

        if let mcp = FastLogJSON.parseMCPToolName(toolName) {
            return .mcpToolCalled(server: mcp.server, tool: mcp.tool)
        }

        let args = FastLogJSON.dictionaryArguments(data["arguments"] ?? data["args"])
        switch toolName {
        case "skill", "use_skill", "activate_skill":
            if let skill = nonEmptyString(args?["skill"]) ?? nonEmptyString(args?["name"]) {
                return .skillInvoked(name: skill)
            }
            return .builtinToolCalled(name: toolName)
        case "agent", "task", "subagent", "custom_agent":
            let subagent =
                nonEmptyString(args?["agent_type"])
                ?? nonEmptyString(args?["subagent_type"])
                ?? nonEmptyString(args?["agent"])
                ?? nonEmptyString(args?["name"])
                ?? toolName
            return .subagentInvoked(name: subagent)
        default:
            return .builtinToolCalled(name: toolName)
        }
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let str = raw as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func fallbackSessionID(for url: URL) -> String {
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? "copilot-session" : parent
    }
}
