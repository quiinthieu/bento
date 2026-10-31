import BentoCore
import BentoParsing
import Foundation

/// Streaming chat transcript decoder for Google Gemini CLI (`PLAN.md` §5.2, §6.2).
///
/// Supports both modern append-only `session-*.jsonl` streams (`session_metadata`, `gemini`,
/// `message_update`) and legacy monolithic `session-*.json` documents (`messages[]`), handling
/// both `tokens` (`input`/`output`/`cached`) and `usageMetadata` (`promptTokenCount`/
/// `candidatesTokenCount`/`cachedContentTokenCount`).
public struct GeminiLogDecoder: LogDecoder, Sendable {
    private struct ResumeState: Codable {
        var activeSessionID: String?
        var activeCwd: String?
        var activeModel: String?
        var observedModels: [String: String]
        var emittedSessionStarts: Set<String>
        var seenUsageMessageIDs: Set<String>
        var seenToolCallIDs: Set<String>
        var turnIndexBySession: [String: Int]
    }

    private var activeSessionID: String?
    private var activeCwd: String?
    private var activeModel: String?
    private var observedModels: [String: String] = [:]
    private var emittedSessionStarts: Set<String> = []
    private var seenUsageMessageIDs: Set<String> = []
    private var seenToolCallIDs: Set<String> = []
    private var turnIndexBySession: [String: Int] = [:]
    private var errors = 0

    /// Creates a Gemini CLI log decoder.
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
            seenUsageMessageIDs: seenUsageMessageIDs,
            seenToolCallIDs: seenToolCallIDs,
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
        seenUsageMessageIDs = state.seenUsageMessageIDs
        seenToolCallIDs = state.seenToolCallIDs
        turnIndexBySession = state.turnIndexBySession
    }

    public mutating func decodeDocument(data: Data, source: LogSource) -> [UsageEvent] {
        switch FastLogJSON.inspectObjectFraming(in: data) {
        case .empty:
            return []
        case .object:
            if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                root["messages"] != nil
            {
                return decodeObject(root, source: source)
            }
        case .invalid:
            break
        }

        // Fall back to line-by-line JSONL decoding.
        var events: [UsageEvent] = []
        var lineStart = 0
        let count = data.count
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for idx in 0..<count where base[idx] == 0x0A {
                var end = idx
                if end > lineStart && base[end - 1] == 0x0D {
                    end -= 1
                }
                if end > lineStart {
                    let slice = Data(bytes: base.advanced(by: lineStart), count: end - lineStart)
                    events.append(contentsOf: decode(line: slice, source: source))
                }
                lineStart = idx + 1
            }
            if lineStart < count {
                var end = count
                if end > lineStart && base[end - 1] == 0x0D {
                    end -= 1
                }
                if end > lineStart {
                    let slice = Data(bytes: base.advanced(by: lineStart), count: end - lineStart)
                    events.append(contentsOf: decode(line: slice, source: source))
                }
            }
        }
        return events
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

        return decodeObject(obj, source: source)
    }

    // MARK: - Core Object Decoding

    private mutating func decodeObject(_ obj: [String: Any], source: LogSource) -> [UsageEvent] {
        if let rawSessionID = Self.nonEmptyString(obj["sessionId"]) ?? Self.nonEmptyString(obj["session_id"]) {
            activeSessionID = rawSessionID
        }
        let sessionID = activeSessionID ?? Self.fallbackSessionID(for: source.url)

        if let rawCwd = Self.nonEmptyString(obj["cwd"]) {
            activeCwd = source.normalizeLoggedCwd(rawCwd)
        } else if activeCwd == nil {
            activeCwd = source.inferredCwd
        }
        let cwd = activeCwd

        if let model = Self.nonEmptyString(obj["model"]) {
            activeModel = model
            observedModels[sessionID] = model
        }

        var emitted: [UsageEvent] = []

        // Legacy monolithic `.json` transcript containing `messages: [...]`
        if let messages = obj["messages"] as? [[String: Any]] {
            let startTS = FastLogJSON.parseTimestamp(obj["startTime"] ?? obj["timestamp"])
            if activeModel == nil {
                for msg in messages {
                    if let m = Self.nonEmptyString(msg["model"]) {
                        activeModel = m
                        observedModels[sessionID] = m
                        break
                    }
                }
            }
            if emittedSessionStarts.insert(sessionID).inserted {
                emitted.append(
                    UsageEvent(
                        agent: .gemini,
                        sessionID: sessionID,
                        timestamp: startTS,
                        cwd: cwd,
                        kind: .sessionStart(model: activeModel)
                    )
                )
            }
            for msg in messages {
                emitted.append(
                    contentsOf: decodeMessageRecord(msg, sessionID: sessionID, cwd: cwd, fallbackTS: startTS))
            }
            return emitted
        }

        let recordType = (obj["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let timestamp = FastLogJSON.parseTimestamp(obj["timestamp"] ?? obj["startTime"])

        switch recordType {
        case "session_metadata":
            if emittedSessionStarts.insert(sessionID).inserted {
                emitted.append(
                    UsageEvent(
                        agent: .gemini,
                        sessionID: sessionID,
                        timestamp: timestamp,
                        cwd: cwd,
                        kind: .sessionStart(model: activeModel)
                    )
                )
            }

        case "gemini", "model", "assistant", "message_update":
            if emittedSessionStarts.insert(sessionID).inserted {
                emitted.append(
                    UsageEvent(
                        agent: .gemini,
                        sessionID: sessionID,
                        timestamp: timestamp,
                        cwd: cwd,
                        kind: .sessionStart(model: activeModel)
                    )
                )
            }
            emitted.append(
                contentsOf: decodeMessageRecord(obj, sessionID: sessionID, cwd: cwd, fallbackTS: timestamp)
            )

        default:
            break
        }

        return emitted
    }

    private mutating func decodeMessageRecord(
        _ msg: [String: Any],
        sessionID: String,
        cwd: String?,
        fallbackTS: Date
    ) -> [UsageEvent] {
        let msgType = (msg["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if msgType == "user" || msgType == "info" || msgType == "error" {
            return []
        }

        if let model = Self.nonEmptyString(msg["model"]) {
            activeModel = model
            observedModels[sessionID] = model
        }

        let timestamp = FastLogJSON.parseTimestamp(msg["timestamp"], fallback: fallbackTS)
        let messageID = Self.nonEmptyString(msg["id"])
        var out: [UsageEvent] = []

        if let (input, cached, output) = Self.extractTokenCounts(from: msg) {
            let shouldEmit: Bool
            if let messageID {
                shouldEmit = seenUsageMessageIDs.insert("\(sessionID)|\(messageID)").inserted
            } else {
                shouldEmit = true
            }
            if shouldEmit && (input > 0 || output > 0) {
                let turnIndex = turnIndexBySession[sessionID, default: 0]
                turnIndexBySession[sessionID] = turnIndex + 1
                out.append(
                    UsageEvent(
                        agent: .gemini,
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
            }
        }

        if let toolCalls = msg["toolCalls"] as? [[String: Any]] {
            for call in toolCalls {
                if let callID = Self.nonEmptyString(call["id"]) {
                    guard seenToolCallIDs.insert("\(sessionID)|\(callID)").inserted else {
                        continue
                    }
                }
                guard let name = Self.nonEmptyString(call["name"]) else { continue }
                let args = FastLogJSON.dictionaryArguments(call["args"] ?? call["arguments"])
                let explicitServer =
                    Self.nonEmptyString(call["serverName"])
                    ?? Self.nonEmptyString(call["mcpServer"])
                let kind = Self.classifyToolCall(name: name, explicitServer: explicitServer, args: args)
                out.append(
                    UsageEvent(
                        agent: .gemini,
                        sessionID: sessionID,
                        timestamp: timestamp,
                        cwd: cwd,
                        kind: kind
                    )
                )
            }
        }

        return out
    }

    // MARK: - Helpers

    private static func extractTokenCounts(from dict: [String: Any]) -> (input: Int, cached: Int?, output: Int)? {
        if let tokens = dict["tokens"] as? [String: Any],
            let input = FastLogJSON.intValue(tokens["input"]) ?? FastLogJSON.intValue(tokens["prompt"])
        {
            let cached = FastLogJSON.intValue(tokens["cached"])
            let output = FastLogJSON.intValue(tokens["output"]) ?? FastLogJSON.intValue(tokens["candidates"]) ?? 0
            return (input, cached, output)
        }
        if let meta = dict["usageMetadata"] as? [String: Any],
            let input = FastLogJSON.intValue(meta["promptTokenCount"])
        {
            let cached = FastLogJSON.intValue(meta["cachedContentTokenCount"])
            let output = FastLogJSON.intValue(meta["candidatesTokenCount"]) ?? 0
            return (input, cached, output)
        }
        return nil
    }

    private static func classifyToolCall(
        name: String,
        explicitServer: String?,
        args: [String: Any]?
    ) -> UsageEvent.Kind {
        if let explicitServer {
            return .mcpToolCalled(server: explicitServer, tool: name)
        }
        if let mcp = FastLogJSON.parseMCPToolName(name) {
            return .mcpToolCalled(server: mcp.server, tool: mcp.tool)
        }
        switch name {
        case "activate_skill", "use_skill", "skill":
            if let skill = nonEmptyString(args?["name"]) ?? nonEmptyString(args?["skill"]) {
                return .skillInvoked(name: skill)
            }
            return .builtinToolCalled(name: name)
        case "delegate_to_agent", "spawn_agent", "subagent":
            let subagent =
                nonEmptyString(args?["name"])
                ?? nonEmptyString(args?["agent"])
                ?? nonEmptyString(args?["agent_name"])
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
        for suffix in [".zst", ".jsonl", ".json"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name.isEmpty ? "gemini-session" : name
    }
}
