import Foundation

/// Single session observation pairing an uncalibrated predicted pre-prompt token count against the
/// logged first-turn input token count (`PLAN.md` §4.2, §6.3).
public struct CalibrationSample: Sendable, Codable, Hashable {
    public var agent: AgentID
    public var sessionID: String
    public var model: String
    public var tokenizerID: String
    public var predictedPrePromptTokens: Int
    public var measuredFirstTurnInput: Int
    public var userMessageEstimatedTokens: Int

    /// First-turn input tokens after subtracting the length-only estimated first user message tokens.
    public var adjustedMeasuredPrePromptTokens: Int {
        max(0, measuredFirstTurnInput - max(0, userMessageEstimatedTokens))
    }

    public init(
        agent: AgentID,
        sessionID: String,
        model: String,
        tokenizerID: String,
        predictedPrePromptTokens: Int,
        measuredFirstTurnInput: Int,
        userMessageEstimatedTokens: Int = 0
    ) {
        self.agent = agent
        self.sessionID = sessionID
        self.model = model
        self.tokenizerID = tokenizerID
        self.predictedPrePromptTokens = predictedPrePromptTokens
        self.measuredFirstTurnInput = measuredFirstTurnInput
        self.userMessageEstimatedTokens = userMessageEstimatedTokens
    }
}

/// Fitted least-squares multiplicative calibration factor `kFactor` persisted in the `calibration`
/// SQLite table per `(agent, model, tokenizerID)` (`PLAN.md` §4.2, §6.3, §11 T12).
public struct CalibrationRecord: Sendable, Codable, Hashable {
    public var agent: AgentID
    public var model: String
    public var tokenizerID: String
    public var kFactor: Double
    public var sampleCount: Int
    public var residualStddev: Double
    public var updatedAt: Date

    public init(
        agent: AgentID,
        model: String,
        tokenizerID: String,
        kFactor: Double,
        sampleCount: Int,
        residualStddev: Double,
        updatedAt: Date
    ) {
        self.agent = agent
        self.model = model
        self.tokenizerID = tokenizerID
        self.kFactor = kFactor
        self.sampleCount = sampleCount
        self.residualStddev = residualStddev
        self.updatedAt = updatedAt
    }
}
