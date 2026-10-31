import BentoCore
import Foundation

/// Fits multiplicative `kFactor` calibration records per `(agent, model, tokenizerID)` by Ordinary Least Squares
/// through the origin from logged first-turn input token observations (`PLAN.md` §4.2, §6.3, §11 T12).
public struct CalibrationFitter: Sendable {
    public static let defaultMinimumSamples = 3
    public static let defaultAllowedKRange: ClosedRange<Double> = 0.25...4.0
    public static let defaultUserMessageCharsPerToken = 4.0

    public var minimumSamples: Int
    public var allowedKRange: ClosedRange<Double>

    public init(
        minimumSamples: Int = Self.defaultMinimumSamples,
        allowedKRange: ClosedRange<Double> = Self.defaultAllowedKRange
    ) {
        self.minimumSamples = max(1, minimumSamples)
        self.allowedKRange = allowedKRange
    }

    /// Estimates the token length of a logged first user message purely from its character count
    /// (`PLAN.md` §6.3: *"subtract the estimated user first message, if logged (length only)"*).
    public static func estimateUserMessageTokens(
        charCount: Int?,
        charsPerToken: Double = Self.defaultUserMessageCharsPerToken
    ) -> Int {
        guard let charCount, charCount > 0, charsPerToken > 0 else {
            return 0
        }
        return max(1, Int((Double(charCount) / charsPerToken).rounded()))
    }

    /// Fits `CalibrationRecord` entries for every `(agent, model, tokenizerID)` bucket containing at least
    /// `minimumSamples` valid observations (`predictedPrePromptTokens > 0 && adjustedMeasuredPrePromptTokens > 0`).
    public func fit(samples: [CalibrationSample], now: Date = Date()) -> [CalibrationRecord] {
        struct BucketKey: Hashable {
            var agent: AgentID
            var model: String
            var tokenizerID: String
        }

        var buckets: [BucketKey: [CalibrationSample]] = [:]
        for sample in samples {
            guard sample.predictedPrePromptTokens > 0, sample.adjustedMeasuredPrePromptTokens > 0 else {
                continue
            }
            let normalizedModel = Self.normalizeModelKey(sample.model)
            let key = BucketKey(
                agent: sample.agent,
                model: normalizedModel,
                tokenizerID: sample.tokenizerID
            )
            buckets[key, default: []].append(sample)
        }

        var records: [CalibrationRecord] = []
        for (key, group) in buckets where group.count >= minimumSamples {
            var sumXY = 0.0
            var sumXX = 0.0
            for item in group {
                let x = Double(item.predictedPrePromptTokens)
                let y = Double(item.adjustedMeasuredPrePromptTokens)
                sumXY += x * y
                sumXX += x * x
            }
            guard sumXX > 0 else { continue }

            let rawK = sumXY / sumXX
            let clampedK = min(max(rawK, allowedKRange.lowerBound), allowedKRange.upperBound)

            var sumSquaredResiduals = 0.0
            for item in group {
                let x = Double(item.predictedPrePromptTokens)
                let y = Double(item.adjustedMeasuredPrePromptTokens)
                let residual = y - clampedK * x
                sumSquaredResiduals += residual * residual
            }
            let degreesOfFreedom = Double(max(1, group.count - 1))
            let residualStddev = (sumSquaredResiduals / degreesOfFreedom).squareRoot()

            records.append(
                CalibrationRecord(
                    agent: key.agent,
                    model: key.model,
                    tokenizerID: key.tokenizerID,
                    kFactor: clampedK,
                    sampleCount: group.count,
                    residualStddev: residualStddev,
                    updatedAt: now
                )
            )
        }

        return records.sorted {
            if $0.agent.rawValue != $1.agent.rawValue {
                return $0.agent.rawValue < $1.agent.rawValue
            }
            if $0.model != $1.model {
                return $0.model < $1.model
            }
            return $0.tokenizerID < $1.tokenizerID
        }
    }

    private static func normalizeModelKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "*" : trimmed
    }
}
