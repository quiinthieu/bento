import BentoCore
import Foundation

/// Maps `(AgentID, model)` pairs to their offline `TokenCounter`, confidence label, provenance method,
/// calibration factor, and context window (`PLAN.md` §6.3, §11 T08).
public struct AgentTokenizerRegistry: TokenCountingProvider, Sendable {
    private struct CalibrationKey: Hashable, Sendable {
        var agent: AgentID
        var normalizedModel: String
    }

    private let o200k: BPETokenizer
    private let cl100k: BPETokenizer
    private let heuristic: HeuristicCounter
    private let cache: CachingTokenCounter
    private var calibrations: [CalibrationKey: Double] = [:]
    private var exactAPICounters: [AgentID: any ExactAPITokenCounting] = [:]

    /// Creates an `AgentTokenizerRegistry` backed by shared `o200k_base` / `cl100k_base` BPE tables and `HeuristicCounter`.
    public init(
        heuristic: HeuristicCounter = HeuristicCounter(),
        cache: CachingTokenCounter = CachingTokenCounter()
    ) throws {
        self.o200k = try BPETokenizer.shared(for: .o200kBase)
        self.cl100k = try BPETokenizer.shared(for: .cl100kBase)
        self.heuristic = heuristic
        self.cache = cache
    }

    /// Registers or removes an opt-in exact API token counter (`AnthropicCountTokens` or `GeminiCountTokens`) for `agent`.
    public mutating func setExactAPICounter(_ counter: (any ExactAPITokenCounting)?, for agent: AgentID) {
        if let counter, counter.isEnabled {
            exactAPICounters[agent] = counter
        } else {
            exactAPICounters.removeValue(forKey: agent)
        }
    }

    /// Returns the uncalibrated base offline `TokenCounter.id` selected for `(agent, model)`.
    public func baseCounterID(for agent: AgentID, model: String?) -> String {
        resolveSelection(for: agent, model: model, sampleText: "").counter.id
    }

    /// Applies persisted `CalibrationRecord` entries to `(agent, model)` pairs, setting a sample-weighted
    /// agent-wide fallback when no explicit `"*"` record exists for that agent.
    public mutating func applyCalibrations(_ records: [CalibrationRecord]) {
        var weightedSumByAgent: [AgentID: Double] = [:]
        var weightTotalByAgent: [AgentID: Int] = [:]
        var hasWildcardByAgent: Set<AgentID> = []

        for record in records where record.sampleCount > 0 {
            let normalizedModel = Self.normalizeModel(record.model)
            setCalibrationFactor(record.kFactor, for: record.agent, model: normalizedModel)
            if normalizedModel == "*" {
                hasWildcardByAgent.insert(record.agent)
            } else {
                weightedSumByAgent[record.agent, default: 0.0] += record.kFactor * Double(record.sampleCount)
                weightTotalByAgent[record.agent, default: 0] += record.sampleCount
            }
        }

        for (agent, totalSamples) in weightTotalByAgent where totalSamples > 0 && !hasWildcardByAgent.contains(agent) {
            if let weightedSum = weightedSumByAgent[agent] {
                setCalibrationFactor(weightedSum / Double(totalSamples), for: agent, model: nil)
            }
        }
    }

    /// Registers or updates a fitted calibration `kFactor` for `(agent, model)` (`nil` sets the agent-wide fallback).
    public mutating func setCalibrationFactor(_ kFactor: Double, for agent: AgentID, model: String? = nil) {
        let key = CalibrationKey(agent: agent, normalizedModel: Self.normalizeModel(model))
        calibrations[key] = max(0.05, kFactor)
    }

    /// Looks up any registered calibration `kFactor` for `(agent, model)` (falling back to agent-wide default).
    public func calibrationFactor(for agent: AgentID, model: String?) -> Double? {
        let exactKey = CalibrationKey(agent: agent, normalizedModel: Self.normalizeModel(model))
        if let exact = calibrations[exactKey] {
            return exact
        }
        let fallbackKey = CalibrationKey(agent: agent, normalizedModel: "*")
        return calibrations[fallbackKey]
    }

    /// Selects the underlying `TokenCounter` for `(agent, model)`.
    public func counter(for agent: AgentID, model: String?) -> any TokenCounter {
        if let apiCounter = exactAPICounters[agent], apiCounter.isEnabled {
            return apiCounter
        }
        let selection = resolveSelection(for: agent, model: model, sampleText: "")
        if let kFactor = calibrationFactor(for: agent, model: model), selection.confidence == .estimated {
            return CalibratedCounter(base: selection.counter, kFactor: kFactor)
        }
        return selection.counter
    }

    public func estimateTokens(
        text: String,
        contentHash: String?,
        agent: AgentID,
        model: String?
    ) -> TokenCountEstimate {
        if let apiCounter = exactAPICounters[agent], apiCounter.isEnabled {
            if let exact = try? apiCounter.countExactSync(text: text, contentHash: contentHash, model: model) {
                return exact
            }
        }

        let selection = resolveSelection(for: agent, model: model, sampleText: text)
        let activeCounter: any TokenCounter
        let methodString: String
        let uncertaintyFraction: Double

        if let kFactor = calibrationFactor(for: agent, model: model), selection.confidence == .estimated {
            activeCounter = CalibratedCounter(base: selection.counter, kFactor: kFactor)
            methodString = String(format: "%@ (calibrated k=%.2f)", selection.method, kFactor)
            uncertaintyFraction = 0.12
        } else {
            activeCounter = selection.counter
            methodString = selection.method
            uncertaintyFraction = selection.uncertaintyFraction
        }

        let count = cache.count(text, contentHash: contentHash, using: activeCounter)
        let range: ClosedRange<Int>?
        if selection.confidence == .exact {
            range = nil
        } else {
            let lo = max(0, Int((Double(count) * (1.0 - uncertaintyFraction)).rounded(.down)))
            let hi = max(lo, Int((Double(count) * (1.0 + uncertaintyFraction)).rounded(.up)))
            range = lo...hi
        }

        return TokenCountEstimate(
            tokens: count,
            range: range,
            confidence: selection.confidence,
            method: methodString,
            counterID: selection.counter.id
        )
    }

    public func contextWindow(for agent: AgentID, model: String?) -> Int? {
        let lower = Self.normalizeModel(model)
        switch agent {
        case .claudeCode:
            if lower.contains("1m") {
                return 1_000_000
            }
            return 200_000

        case .codex:
            if lower.hasPrefix("gpt-5") || lower.contains("codex") {
                return 400_000
            }
            if lower.hasPrefix("gpt-4.1") {
                return 1_047_576
            }
            if lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4") {
                return 200_000
            }
            if lower.hasPrefix("gpt-4o") || lower.hasPrefix("gpt-4-turbo") {
                return 128_000
            }
            if lower.hasPrefix("gpt-4") {
                return 8_192
            }
            if lower.hasPrefix("gpt-3.5") {
                return 16_385
            }
            return 200_000

        case .gemini:
            return 1_048_576

        case .copilot:
            if lower.contains("claude") {
                return 200_000
            }
            if lower.contains("gemini") {
                return 1_048_576
            }
            if lower.hasPrefix("gpt-4.1") {
                return 1_047_576
            }
            if lower.hasPrefix("o3") || lower.hasPrefix("o4") || lower.hasPrefix("gpt-5") {
                return 200_000
            }
            return 128_000

        case .cursor, .windsurf:
            return nil
        }
    }

    // MARK: - Private Model Mapping

    private struct CounterSelection {
        var counter: any TokenCounter
        var confidence: Confidence
        var method: String
        var uncertaintyFraction: Double
    }

    private func resolveSelection(for agent: AgentID, model: String?, sampleText: String) -> CounterSelection {
        let lower = Self.normalizeModel(model)

        switch agent {
        case .codex:
            // Default Codex CLI models are OpenAI o200k_base models (`gpt-5-codex`, `codex-mini`, `o3`, `o4-mini`).
            if lower == "*" || Self.isOpenAIO200kModel(lower) {
                return CounterSelection(
                    counter: o200k,
                    confidence: .exact,
                    method: o200k.id,
                    uncertaintyFraction: 0.0
                )
            }
            if Self.isOpenAICl100kModel(lower) {
                return CounterSelection(
                    counter: cl100k,
                    confidence: .exact,
                    method: cl100k.id,
                    uncertaintyFraction: 0.0
                )
            }
            return CounterSelection(
                counter: o200k,
                confidence: .estimated,
                method: "\(o200k.id) (unrecognized model proxy)",
                uncertaintyFraction: 0.15
            )

        case .claudeCode, .gemini:
            return CounterSelection(
                counter: heuristic,
                confidence: .estimated,
                method: heuristic.methodDescription(for: sampleText),
                uncertaintyFraction: 0.15
            )

        case .copilot:
            if Self.isOpenAIO200kModel(lower) {
                return CounterSelection(
                    counter: o200k,
                    confidence: .exact,
                    method: o200k.id,
                    uncertaintyFraction: 0.0
                )
            }
            if Self.isOpenAICl100kModel(lower) {
                return CounterSelection(
                    counter: cl100k,
                    confidence: .exact,
                    method: cl100k.id,
                    uncertaintyFraction: 0.0
                )
            }
            if lower.contains("claude") || lower.contains("gemini") {
                return CounterSelection(
                    counter: heuristic,
                    confidence: .estimated,
                    method: heuristic.methodDescription(for: sampleText),
                    uncertaintyFraction: 0.15
                )
            }
            return CounterSelection(
                counter: o200k,
                confidence: .estimated,
                method: "\(o200k.id) (default model proxy)",
                uncertaintyFraction: 0.15
            )

        case .cursor, .windsurf:
            return CounterSelection(
                counter: heuristic,
                confidence: .estimated,
                method: heuristic.methodDescription(for: sampleText),
                uncertaintyFraction: 0.15
            )
        }
    }

    private static func normalizeModel(_ model: String?) -> String {
        guard let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return "*"
        }
        return trimmed.lowercased()
    }

    private static func isOpenAIO200kModel(_ lower: String) -> Bool {
        let prefixes = [
            "gpt-5",
            "gpt-4o",
            "gpt-4.1",
            "gpt-4.5",
            "chatgpt-4o",
            "codex",
            "o1",
            "o3",
            "o4"
        ]
        return prefixes.contains { lower.hasPrefix($0) }
    }

    private static func isOpenAICl100kModel(_ lower: String) -> Bool {
        let gpt4Matches =
            lower == "gpt-4"
            || lower.hasPrefix("gpt-4-")
            || lower.hasPrefix("gpt-4-0")
            || lower.hasPrefix("gpt-4-1")
            || lower.hasPrefix("gpt-4-32k")
            || lower.hasPrefix("gpt-4-turbo")
        if gpt4Matches {
            return !lower.hasPrefix("gpt-4o")
        }
        return lower.hasPrefix("gpt-3.5")
            || lower.hasPrefix("text-embedding-3")
            || lower.hasPrefix("text-embedding-ada")
    }
}
