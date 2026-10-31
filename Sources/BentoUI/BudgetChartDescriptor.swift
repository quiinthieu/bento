import BentoCore
import Foundation

/// Single stacked-bar segment in the per-agent Budget chart, paired with VoiceOver descriptions (`PLAN.md` §6.7).
public struct BudgetChartSegment: Sendable, Identifiable, Hashable {
    public var id: String
    public var agent: AgentID
    public var category: BudgetCategory
    public var categoryDisplayName: String
    public var tokens: Int
    public var isPrePrompt: Bool
    public var dominantConfidence: Confidence
    public var accessibilityLabel: String
    public var accessibilityValue: String

    public init(
        id: String,
        agent: AgentID,
        category: BudgetCategory,
        categoryDisplayName: String,
        tokens: Int,
        isPrePrompt: Bool,
        dominantConfidence: Confidence,
        accessibilityLabel: String,
        accessibilityValue: String
    ) {
        self.id = id
        self.agent = agent
        self.category = category
        self.categoryDisplayName = categoryDisplayName
        self.tokens = tokens
        self.isPrePrompt = isPrePrompt
        self.dominantConfidence = dominantConfidence
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
    }
}

/// Aggregated chart model for one agent's `Budget` row, including solid pre-prompt segments,
/// hatched deferred/on-invoke segments, and the optional measured first-turn median marker (`PLAN.md` §6.7).
public struct BudgetChartSummary: Sendable, Identifiable, Hashable {
    public var id: AgentID { agent }
    public var agent: AgentID
    public var agentDisplayName: String
    public var model: String?
    public var prePromptTokens: Int
    public var deferredTokens: Int
    public var measuredFirstTurnInput: Int?
    public var contextWindow: Int?
    public var segments: [BudgetChartSegment]
    public var measuredMarkerAccessibilityLabel: String?
    public var chartSummaryAccessibilityLabel: String

    public static func build(from budget: Budget) -> BudgetChartSummary {
        struct BucketKey: Hashable {
            var category: BudgetCategory
            var isPrePrompt: Bool
        }

        var tokensByBucket: [BucketKey: Int] = [:]
        var confidencesByBucket: [BucketKey: [Confidence]] = [:]

        for item in budget.items where item.tokens > 0 {
            let key = BucketKey(category: item.category, isPrePrompt: item.countsTowardPrePrompt)
            tokensByBucket[key, default: 0] += item.tokens
            confidencesByBucket[key, default: []].append(item.confidence)
        }

        var orderedSegments: [BudgetChartSegment] = []
        // Emit pre-prompt segments first in BudgetCategory order, followed by deferred/on-invoke hatched segments.
        for isPrePromptPass in [true, false] {
            for category in BudgetCategory.allCases {
                let key = BucketKey(category: category, isPrePrompt: isPrePromptPass)
                guard let total = tokensByBucket[key], total > 0 else { continue }
                let confidences = confidencesByBucket[key] ?? [.estimated]
                let dominant = dominantConfidence(from: confidences)
                let modeText = isPrePromptPass ? "pre-prompt always loaded" : "deferred or on-invoke"
                let segID = "\(budget.agent.rawValue):\(category.rawValue):\(isPrePromptPass ? "pre" : "def")"
                let axLabel = "\(budget.agent.displayName), \(category.displayName)"
                let axValue = "\(total) tokens, \(modeText), \(dominant.rawValue)"

                orderedSegments.append(
                    BudgetChartSegment(
                        id: segID,
                        agent: budget.agent,
                        category: category,
                        categoryDisplayName: category.displayName,
                        tokens: total,
                        isPrePrompt: isPrePromptPass,
                        dominantConfidence: dominant,
                        accessibilityLabel: axLabel,
                        accessibilityValue: axValue
                    )
                )
            }
        }

        let prePrompt = budget.prePromptTokens
        let deferred = budget.items.reduce(0) { sum, item in
            item.countsTowardPrePrompt ? sum : sum + item.tokens
        }

        let markerAX: String?
        if let measured = budget.measuredFirstTurnInput {
            markerAX = "Measured first-turn median for \(budget.agent.displayName): \(measured) input tokens"
        } else {
            markerAX = nil
        }

        var summaryParts = [
            "\(budget.agent.displayName): \(prePrompt) pre-prompt tokens"
        ]
        if deferred > 0 {
            summaryParts.append("\(deferred) deferred or on-invoke tokens")
        }
        if let measured = budget.measuredFirstTurnInput {
            summaryParts.append("measured first-turn median \(measured) tokens")
        }
        if let window = budget.contextWindow, window > 0 {
            let pct = Int(((Double(prePrompt) / Double(window)) * 100.0).rounded())
            summaryParts.append("\(pct)% of \(window) token context window")
        }

        return BudgetChartSummary(
            agent: budget.agent,
            agentDisplayName: budget.agent.displayName,
            model: budget.model,
            prePromptTokens: prePrompt,
            deferredTokens: deferred,
            measuredFirstTurnInput: budget.measuredFirstTurnInput,
            contextWindow: budget.contextWindow,
            segments: orderedSegments,
            measuredMarkerAccessibilityLabel: markerAX,
            chartSummaryAccessibilityLabel: summaryParts.joined(separator: ", ")
        )
    }

    private static func dominantConfidence(from values: [Confidence]) -> Confidence {
        if values.allSatisfy({ $0 == .exact }) {
            return .exact
        }
        if values.contains(.measured) && !values.contains(.estimated) {
            return .measured
        }
        return .estimated
    }
}
