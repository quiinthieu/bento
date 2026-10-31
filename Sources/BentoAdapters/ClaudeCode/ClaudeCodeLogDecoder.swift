import BentoCore
import BentoParsing
import Foundation

/// Streaming JSONL session log decoder for Anthropic Claude Code (`PLAN.md` §5.2, §6.2).
///
/// Deduplicates streamed assistant chunks by `message.id` / `requestId` and individual `tool_use`
/// content blocks by `tool_use.id`, extracting only privacy-safe counts, tool/skill/subagent/command
/// names, timestamps, `cwd`, and model identifiers.
public struct ClaudeCodeLogDecoder: LogDecoder, Sendable {
    private struct ResumeState: Codable {
        var activeSessionID: String?
        var activeCwd: String?
        var observedModels: [String: String]
        var firstUserCharCounts: [String: Int]?
        var emittedSessionStarts: Set<String>
        var seenUsageTurnKeys: Set<String>
        var seenToolUseIDs: Set<String>
        var turnIndexBySession: [String: Int]
    }

    private var activeSessionID: String?
    private var activeCwd: String?
    private var observedModels: [String: String] = [:]
    private var firstUserCharCounts: [String: Int] = [:]
    private var emittedSessionStarts: Set<String> = []
    private var seenUsageTurnKeys: Set<String> = []
    private var seenToolUseIDs: Set<String> = []
    private var turnIndexBySession: [String: Int] = [:]
    private var errors = 0

    /// Creates a fresh Claude Code log decoder.
    public init() {}

    public var errorCount: Int {
        errors
    }

    public var observedModelsBySession: [String: String] {
        observedModels
    }

    public var firstUserMessageCharCountsBySession: [String: Int] {
        firstUserCharCounts
    }

    public func exportResumeState() -> Data? {
        let state = ResumeState(
            activeSessionID: activeSessionID,
            activeCwd: activeCwd,
            observedModels: observedModels,
            firstUserCharCounts: firstUserCharCounts,
            emittedSessionStarts: emittedSessionStarts,
            seenUsageTurnKeys: seenUsageTurnKeys,
            seenToolUseIDs: seenToolUseIDs,
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
        observedModels = state.observedModels
        firstUserCharCounts = state.firstUserCharCounts ?? [:]
        emittedSessionStarts = state.emittedSessionStarts
        seenUsageTurnKeys = state.seenUsageTurnKeys
        seenToolUseIDs = state.seenToolUseIDs
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
        let rawSessionID = (obj["sessionId"] as? String) ?? (obj["session_id"] as? String)
        if let trimmed = rawSessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            activeSessionID = trimmed
        }
        let sessionID = activeSessionID ?? Self.fallbackSessionID(for: source.url)

        if let rawCwd = obj["cwd"] as? String {
            activeCwd = source.normalizeLoggedCwd(rawCwd)
        } else if activeCwd == nil {
            activeCwd = source.inferredCwd
        }
        let cwd = activeCwd

        let timestamp = FastLogJSON.parseTimestamp(obj["timestamp"])
        let messageDict = obj["message"] as? [String: Any]

        let observedModel = Self.nonEmptyString(messageDict?["model"]) ?? Self.nonEmptyString(obj["model"])
        if let observedModel {
            observedModels[sessionID] = observedModel
        }

        var emitted: [UsageEvent] = []

        func ensureSessionStarted(initialModel: String?) {
            if emittedSessionStarts.insert(sessionID).inserted {
                emitted.append(
                    UsageEvent(
                        agent: .claudeCode,
                        sessionID: sessionID,
                        timestamp: timestamp,
                        cwd: cwd,
                        kind: .sessionStart(model: initialModel)
                    )
                )
            }
        }

        switch recordType {
        case "summary", "system":
            ensureSessionStarted(initialModel: Self.nonEmptyString(obj["model"]))

        case "user":
            ensureSessionStarted(initialModel: nil)
            let userContent = messageDict?["content"] ?? obj["content"]
            if firstUserCharCounts[sessionID] == nil {
                let charLen = Self.measureContentCharacterLength(userContent)
                if charLen > 0 {
                    firstUserCharCounts[sessionID] = charLen
                }
            }
            for cmdName in Self.extractSlashCommands(from: userContent) {
                emitted.append(
                    UsageEvent(
                        agent: .claudeCode,
                        sessionID: sessionID,
                        timestamp: timestamp,
                        cwd: cwd,
                        kind: .commandInvoked(name: cmdName)
                    )
                )
            }

        case "assistant":
            ensureSessionStarted(initialModel: observedModel)

            let messageID = Self.nonEmptyString(messageDict?["id"])
            let requestID = Self.nonEmptyString(obj["requestId"]) ?? Self.nonEmptyString(obj["request_id"])
            let turnDedupeKey = (messageID ?? requestID).map { "\(sessionID)|\($0)" }

            if let usageDict = (messageDict?["usage"] as? [String: Any]) ?? (obj["usage"] as? [String: Any]) {
                let shouldEmitUsage: Bool
                if let turnDedupeKey {
                    shouldEmitUsage = seenUsageTurnKeys.insert(turnDedupeKey).inserted
                } else {
                    shouldEmitUsage = true
                }

                if shouldEmitUsage {
                    let baseInput = FastLogJSON.intValue(usageDict["input_tokens"]) ?? 0
                    let cacheCreate = FastLogJSON.intValue(usageDict["cache_creation_input_tokens"])
                    let cacheRead = FastLogJSON.intValue(usageDict["cache_read_input_tokens"])
                    let output = FastLogJSON.intValue(usageDict["output_tokens"]) ?? 0
                    let totalInput = baseInput + (cacheCreate ?? 0) + (cacheRead ?? 0)
                    let cachedInput: Int? = (cacheRead != nil || cacheCreate != nil) ? (cacheRead ?? 0) : nil

                    if totalInput > 0 || output > 0 {
                        let turnIndex = turnIndexBySession[sessionID, default: 0]
                        turnIndexBySession[sessionID] = turnIndex + 1
                        emitted.append(
                            UsageEvent(
                                agent: .claudeCode,
                                sessionID: sessionID,
                                timestamp: timestamp,
                                cwd: cwd,
                                kind: .tokenUsage(
                                    input: totalInput,
                                    cachedInput: cachedInput,
                                    output: output,
                                    turnIndex: turnIndex
                                )
                            )
                        )
                    }
                }
            }

            if let contentArray = messageDict?["content"] as? [[String: Any]] {
                for block in contentArray {
                    guard (block["type"] as? String) == "tool_use" else { continue }
                    if let toolUseID = Self.nonEmptyString(block["id"]) {
                        let scopedID = "\(sessionID)|\(toolUseID)"
                        guard seenToolUseIDs.insert(scopedID).inserted else {
                            continue
                        }
                    }
                    guard let toolName = Self.nonEmptyString(block["name"]) else { continue }
                    let inputDict = FastLogJSON.dictionaryArguments(block["input"])
                    if let kind = Self.classifyToolUse(name: toolName, input: inputDict) {
                        emitted.append(
                            UsageEvent(
                                agent: .claudeCode,
                                sessionID: sessionID,
                                timestamp: timestamp,
                                cwd: cwd,
                                kind: kind
                            )
                        )
                    }
                }
            }

        default:
            break
        }

        return emitted
    }

    // MARK: - Helpers

    private static func classifyToolUse(name: String, input: [String: Any]?) -> UsageEvent.Kind? {
        if let mcp = FastLogJSON.parseMCPToolName(name) {
            return .mcpToolCalled(server: mcp.server, tool: mcp.tool)
        }
        switch name {
        case "Skill":
            if let skillName = nonEmptyString(input?["skill"]) ?? nonEmptyString(input?["name"]) {
                return .skillInvoked(name: stripLeadingSlash(skillName))
            }
            return nil
        case "Task", "Agent", "dispatch_agent":
            let subagent =
                nonEmptyString(input?["subagent_type"])
                ?? nonEmptyString(input?["agent_type"])
                ?? nonEmptyString(input?["name"])
                ?? name
            return .subagentInvoked(name: subagent)
        case "SlashCommand":
            if let rawCmd = nonEmptyString(input?["command"]),
                let cleaned = sanitizeCommandToken(rawCmd)
            {
                return .commandInvoked(name: cleaned)
            }
            return nil
        default:
            return .builtinToolCalled(name: name)
        }
    }

    private static func measureContentCharacterLength(_ content: Any?) -> Int {
        if let single = content as? String {
            return single.count
        }
        if let blocks = content as? [[String: Any]] {
            var sum = 0
            for block in blocks {
                if (block["type"] as? String) == "tool_result" { continue }
                if let text = block["text"] as? String {
                    sum += text.count
                }
            }
            return sum
        }
        return 0
    }

    private static func extractSlashCommands(from content: Any?) -> [String] {
        var texts: [String] = []
        if let single = content as? String {
            texts.append(single)
        } else if let blocks = content as? [[String: Any]] {
            for block in blocks {
                if let text = block["text"] as? String {
                    texts.append(text)
                }
            }
        }
        guard !texts.isEmpty else { return [] }

        var commands: [String] = []
        let openTag = "<command-name>"
        let closeTag = "</command-name>"
        for text in texts where text.contains(openTag) {
            var searchStart = text.startIndex
            while let openRange = text.range(of: openTag, range: searchStart..<text.endIndex),
                let closeRange = text.range(of: closeTag, range: openRange.upperBound..<text.endIndex)
            {
                let inner = String(text[openRange.upperBound..<closeRange.lowerBound])
                if let token = sanitizeCommandToken(inner) {
                    commands.append(token)
                }
                searchStart = closeRange.upperBound
            }
        }
        return commands
    }

    private static func sanitizeCommandToken(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let firstPart = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let stripped = stripLeadingSlash(firstPart)
        guard !stripped.isEmpty, stripped.count <= 128 else { return nil }
        let valid = stripped.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-"
                || scalar == "_"
                || scalar == ":"
                || scalar == "."
        }
        return valid ? stripped : nil
    }

    private static func stripLeadingSlash(_ value: String) -> String {
        if value.hasPrefix("/") {
            return String(value.dropFirst())
        }
        return value
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
        return name.isEmpty ? "claude-session" : name
    }
}
