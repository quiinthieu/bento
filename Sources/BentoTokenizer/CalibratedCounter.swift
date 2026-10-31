import BentoCore
import Foundation

/// Scales a base `TokenCounter` by a least-squares calibration factor `kFactor` fitted from session logs (`PLAN.md` §6.3).
public struct CalibratedCounter: TokenCounter, Sendable {
    /// Underlying uncalibrated counter.
    public let base: any TokenCounter

    /// Multiplicative calibration factor (`base.count(text) * kFactor`).
    public let kFactor: Double

    /// Stable identifier combining `base.id` and `kFactor`.
    public var id: String {
        String(format: "%@@k=%.4f", base.id, kFactor)
    }

    /// Creates a calibrated token counter wrapper.
    public init(base: any TokenCounter, kFactor: Double) {
        self.base = base
        self.kFactor = max(0.05, kFactor)
    }

    /// Counts tokens using `base` scaled by `kFactor`.
    public func count(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let raw = base.count(text)
        return max(0, Int((Double(raw) * kFactor).rounded()))
    }
}
