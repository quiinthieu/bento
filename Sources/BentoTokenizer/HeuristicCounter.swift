import BentoCore
import Foundation

/// Offline character-ratio token estimator with distinct divisors for prose, code, and JSON (`PLAN.md` §6.3).
public struct HeuristicCounter: TokenCounter, Sendable, Hashable {
    /// Content classification driving the chars-per-token divisor.
    public enum ContentKind: String, Sendable, Codable, Hashable {
        case prose
        case code
        case json
    }

    /// Stable counter identifier.
    public let id: String

    /// UTF-8 bytes per token divisor for natural language and Markdown prose.
    public let proseCharsPerToken: Double

    /// UTF-8 bytes per token divisor for source code and TOML/YAML configuration.
    public let codeCharsPerToken: Double

    /// UTF-8 bytes per token divisor for JSON and JSON-Schema payloads.
    public let jsonCharsPerToken: Double

    /// Creates a heuristic token counter with configurable per-kind divisors.
    public init(
        id: String = "heuristic",
        proseCharsPerToken: Double = 4.60,
        codeCharsPerToken: Double = 4.10,
        jsonCharsPerToken: Double = 3.75
    ) {
        self.id = id
        self.proseCharsPerToken = max(0.5, proseCharsPerToken)
        self.codeCharsPerToken = max(0.5, codeCharsPerToken)
        self.jsonCharsPerToken = max(0.5, jsonCharsPerToken)
    }

    /// Classifies `text` as `.json`, `.code`, or `.prose` from structural character density.
    public func classify(_ text: String) -> ContentKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .prose }

        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
            || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
        {
            var jsonStructural = 0
            var totalNonSpace = 0
            for byte in trimmed.utf8 {
                if byte == 32 || byte == 9 || byte == 10 || byte == 13 { continue }
                totalNonSpace += 1
                switch byte {
                case UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "["), UInt8(ascii: "]"),
                    UInt8(ascii: ":"), UInt8(ascii: "\""), UInt8(ascii: ","):
                    jsonStructural += 1
                default:
                    break
                }
            }
            if totalNonSpace > 0 && Double(jsonStructural) / Double(totalNonSpace) >= 0.14 {
                return .json
            }
        }

        var codeSymbols = 0
        var totalNonSpace = 0
        for byte in trimmed.utf8 {
            if byte == 32 || byte == 9 || byte == 10 || byte == 13 { continue }
            totalNonSpace += 1
            switch byte {
            case UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "("), UInt8(ascii: ")"),
                UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: ";"), UInt8(ascii: "="),
                UInt8(ascii: "<"), UInt8(ascii: ">"):
                codeSymbols += 1
            default:
                break
            }
        }

        if totalNonSpace > 0 && Double(codeSymbols) / Double(totalNonSpace) >= 0.09 {
            return .code
        }
        return .prose
    }

    /// Returns the chars-per-token divisor selected for `kind`.
    public func divisor(for kind: ContentKind) -> Double {
        switch kind {
        case .prose:
            return proseCharsPerToken
        case .code:
            return codeCharsPerToken
        case .json:
            return jsonCharsPerToken
        }
    }

    /// Human-readable provenance method string for `text` (for example `"heuristic chars/3.85"`).
    public func methodDescription(for text: String) -> String {
        let kind = classify(text)
        let div = divisor(for: kind)
        return String(format: "heuristic chars/%.2f", div)
    }

    /// Estimates the token count of `text`.
    public func count(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let kind = classify(text)
        let div = divisor(for: kind)
        return max(1, Int((Double(text.utf8.count) / div).rounded()))
    }
}
