import Foundation

/// Deterministic, modality- and language-scope-aware opposing directive evaluator (`PLAN.md` §6.5).
struct ConflictDetector: Sendable {
    struct UnitStance: Sendable, Hashable {
        var ruleID: String
        var topic: String
        var stanceLabel: String
        var languages: Set<String>
    }

    private struct CompiledRule: Sendable {
        var definition: ConflictRuleDefinition
        var subjectTokenSequences: [[String]]
        var choiceSequences: [(label: String, sequences: [[String]])]
        var positiveSequences: [[String]]
        var negativeSequences: [[String]]
        var exceptionSequences: [[String]]
        var regexes: [NSRegularExpression]
    }

    private static let positiveModalityWords: Set<String> = [
        "use", "prefer", "always", "must", "should", "require", "required",
        "enforce", "keep", "target", "run", "write", "format", "indent",
        "adopt", "standardize", "pin", "limit", "wrap", "include", "enable"
    ]

    private static let permissiveWords: Set<String> = [
        "may", "can", "optional", "optionally", "either"
    ]

    private static let singleNegationMarkers: Set<String> = [
        "never", "not", "no", "don't", "dont", "mustn't", "shouldn't",
        "avoid", "forbid", "forbidden", "prohibit", "disallow", "ban",
        "without", "over", "replace", "replacing", "omit"
    ]

    private static let twoWordNegationMarkers: Set<[String]> = [
        ["do", "not"],
        ["must", "not"],
        ["should", "not"],
        ["instead", "of"],
        ["rather", "than"],
        ["migrate", "from"],
        ["migrating", "from"],
        ["switch", "from"]
    ]

    private static let clauseBreakers: Set<String> = [
        "and", "but", "while", "whereas", "or"
    ]

    private static let languageAliases: [String: String] = [
        "swift": "swift",
        "typescript": "typescript",
        "ts": "typescript",
        "tsx": "typescript",
        "javascript": "javascript",
        "js": "javascript",
        "jsx": "javascript",
        "python": "python",
        "py": "python",
        "rust": "rust",
        "go": "go",
        "golang": "go",
        "java": "java",
        "kotlin": "kotlin",
        "ruby": "ruby",
        "cpp": "cpp",
        "c++": "cpp",
        "sql": "sql",
        "yaml": "yaml",
        "yml": "yaml",
        "json": "json",
        "markdown": "markdown",
        "css": "css",
        "html": "html"
    ]

    private let compiledRules: [CompiledRule]

    init(catalog: ConflictCatalogDocument) {
        self.compiledRules = catalog.rules.map { def in
            let subjects = (def.subjectTerms ?? []).map { MinHashLSH.wordTokens($0.lowercased()) }.filter {
                !$0.isEmpty
            }
            let choices = (def.choices ?? []).map { choice in
                let seqs = choice.terms.map { MinHashLSH.wordTokens($0.lowercased()) }.filter { !$0.isEmpty }
                return (label: choice.label, sequences: seqs)
            }
            let positives = (def.positivePhrases ?? []).map { MinHashLSH.wordTokens($0.lowercased()) }.filter {
                !$0.isEmpty
            }
            let negatives = (def.negativePhrases ?? []).map { MinHashLSH.wordTokens($0.lowercased()) }.filter {
                !$0.isEmpty
            }
            let exceptions = (def.exceptionTerms ?? []).map { MinHashLSH.wordTokens($0.lowercased()) }.filter {
                !$0.isEmpty
            }
            let regexes = (def.patterns ?? []).compactMap {
                try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
            }
            return CompiledRule(
                definition: def,
                subjectTokenSequences: subjects,
                choiceSequences: choices,
                positiveSequences: positives,
                negativeSequences: negatives,
                exceptionSequences: exceptions,
                regexes: regexes
            )
        }
    }

    /// Extracts all unambiguous directive stances asserted by a single normalized rule unit.
    func extractStances(for normalizedText: String) -> [UnitStance] {
        let words = MinHashLSH.wordTokens(normalizedText)
        guard !words.isEmpty else { return [] }
        let languages = Self.detectLanguages(in: words, normalizedText: normalizedText)

        var stances: [UnitStance] = []
        for rule in compiledRules {
            switch rule.definition.kind {
            case .exclusiveChoice:
                if let label = evaluateExclusiveChoice(rule, words: words) {
                    stances.append(
                        UnitStance(
                            ruleID: rule.definition.id,
                            topic: rule.definition.topic,
                            stanceLabel: label,
                            languages: languages
                        )
                    )
                }

            case .polarityOpposition:
                if let label = evaluatePolarityOpposition(rule, words: words, normalizedText: normalizedText) {
                    stances.append(
                        UnitStance(
                            ruleID: rule.definition.id,
                            topic: rule.definition.topic,
                            stanceLabel: label,
                            languages: languages
                        )
                    )
                }

            case .numericValue:
                if let label = evaluateNumericValue(rule, words: words, normalizedText: normalizedText) {
                    stances.append(
                        UnitStance(
                            ruleID: rule.definition.id,
                            topic: rule.definition.topic,
                            stanceLabel: label,
                            languages: languages
                        )
                    )
                }
            }
        }
        return stances
    }

    /// Returns `true` when two stance records represent an opposing conflict on compatible language scopes.
    static func areConflicting(_ lhs: UnitStance, _ rhs: UnitStance) -> Bool {
        guard lhs.ruleID == rhs.ruleID, lhs.stanceLabel != rhs.stanceLabel else {
            return false
        }
        if !lhs.languages.isEmpty && !rhs.languages.isEmpty && lhs.languages.isDisjoint(with: rhs.languages) {
            return false
        }
        return true
    }

    // MARK: - Rule Archetype Evaluators

    private func evaluateExclusiveChoice(_ rule: CompiledRule, words: [String]) -> String? {
        // Ignore permissive non-directives ("you may use npm or pnpm").
        if words.contains(where: { Self.permissiveWords.contains($0) }) {
            return nil
        }

        // Require directive modality word somewhere in the unit.
        guard words.contains(where: { Self.positiveModalityWords.contains($0) }) else {
            return nil
        }

        if !rule.subjectTokenSequences.isEmpty {
            let hasSubject = rule.subjectTokenSequences.contains { seq in
                !Self.findSequenceIndices(seq, in: words).isEmpty
            }
            guard hasSubject else { return nil }
        }

        var endorsedLabels: Set<String> = []
        for choice in rule.choiceSequences {
            for seq in choice.sequences {
                let positions = Self.findSequenceIndices(seq, in: words)
                for pos in positions {
                    // Guard against `npm run` / `npm test` script execution phrases falsely asserting `npm` package manager.
                    if rule.definition.id == "js-package-manager",
                        seq == ["npm"],
                        pos + 1 < words.count,
                        words[pos + 1] == "run" || words[pos + 1] == "test"
                    {
                        continue
                    }

                    if !Self.isNegatedOrRejected(beforeIndex: pos, in: words) {
                        endorsedLabels.insert(choice.label)
                    }
                }
            }
        }

        // Only emit an exclusive stance when the rule unit endorses a single unambiguous choice.
        guard endorsedLabels.count == 1, let single = endorsedLabels.first else {
            return nil
        }
        return single
    }

    private func evaluatePolarityOpposition(
        _ rule: CompiledRule,
        words: [String],
        normalizedText: String
    ) -> String? {
        if !rule.exceptionSequences.isEmpty {
            let hasException = rule.exceptionSequences.contains { seq in
                if seq.count == 1, let token = seq.first, token.contains(".") {
                    return normalizedText.contains(token)
                }
                return !Self.findSequenceIndices(seq, in: words).isEmpty
            }
            if hasException {
                return nil
            }
        }

        let hasNegative = rule.negativeSequences.contains { seq in
            !Self.findSequenceIndices(seq, in: words).isEmpty
        }

        var hasPositive = false
        for seq in rule.positiveSequences {
            let positions = Self.findSequenceIndices(seq, in: words)
            for pos in positions where !Self.isNegatedOrRejected(beforeIndex: pos, in: words) {
                hasPositive = true
                break
            }
            if hasPositive { break }
        }

        if hasPositive && !hasNegative {
            return "required"
        }
        if hasNegative && !hasPositive {
            return "prohibited"
        }
        return nil
    }

    private func evaluateNumericValue(
        _ rule: CompiledRule,
        words: [String],
        normalizedText: String
    ) -> String? {
        let nsRange = NSRange(normalizedText.startIndex..<normalizedText.endIndex, in: normalizedText)
        var capturedValues: Set<String> = []

        for regex in rule.regexes {
            let matches = regex.matches(in: normalizedText, options: [], range: nsRange)
            for match in matches where match.numberOfRanges >= 2 {
                let captureRange = match.range(at: 1)
                guard let swiftRange = Range(captureRange, in: normalizedText),
                    let fullRange = Range(match.range(at: 0), in: normalizedText)
                else {
                    continue
                }

                // Ignore negated numeric mentions like "do not use 2 spaces" or "avoid Node.js 18".
                let prefixText = String(normalizedText[..<fullRange.lowerBound])
                let prefixWords = MinHashLSH.wordTokens(prefixText)
                if Self.isNegatedOrRejected(beforeIndex: prefixWords.count, in: prefixWords) {
                    continue
                }

                let rawValue = String(normalizedText[swiftRange])
                if let unit = rule.definition.unit, !unit.isEmpty {
                    capturedValues.insert("\(rawValue) \(unit)")
                } else {
                    capturedValues.insert(rawValue)
                }
            }
        }

        guard capturedValues.count == 1, let single = capturedValues.first else {
            return nil
        }
        return single
    }

    // MARK: - Token Sequence & Local Modality Helpers

    private static func findSequenceIndices(_ sequence: [String], in words: [String]) -> [Int] {
        guard !sequence.isEmpty, words.count >= sequence.count else { return [] }
        let limit = words.count - sequence.count
        var matches: [Int] = []
        for start in 0...limit {
            var ok = true
            for offset in 0..<sequence.count where words[start + offset] != sequence[offset] {
                ok = false
                break
            }
            if ok {
                matches.append(start)
            }
        }
        return matches
    }

    private static func isNegatedOrRejected(beforeIndex targetIndex: Int, in words: [String]) -> Bool {
        guard targetIndex > 0 else { return false }
        let windowStart = max(0, targetIndex - 4)
        var idx = targetIndex - 1
        while idx >= windowStart {
            let word = words[idx]
            if clauseBreakers.contains(word) {
                break
            }
            if singleNegationMarkers.contains(word) {
                return true
            }
            if idx > 0 {
                let pair = [words[idx - 1], word]
                if twoWordNegationMarkers.contains(pair) {
                    return true
                }
            }
            idx -= 1
        }
        return false
    }

    private static func detectLanguages(in words: [String], normalizedText: String) -> Set<String> {
        // Explicit universal qualifiers ("across all source files", "in all files") override language scoping.
        if normalizedText.contains("all source files") || normalizedText.contains("all files") {
            return []
        }
        var result: Set<String> = []
        for word in words {
            if let canonical = languageAliases[word] {
                result.insert(canonical)
            }
        }
        return result
    }
}
