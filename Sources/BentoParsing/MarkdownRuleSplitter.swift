import Foundation

/// Splits Markdown rule documents into normalized `RuleUnit` spans (`PLAN.md` §6.5).
public enum MarkdownRuleSplitter {
    private static let nonSentenceAbbreviations: Set<String> = [
        "e.g.",
        "i.e.",
        "etc.",
        "vs.",
        "cf.",
        "mr.",
        "mrs.",
        "ms.",
        "dr.",
        "st.",
        "no.",
        "fig.",
        "inc.",
        "ltd.",
        "approx."
    ]

    /// Strips any leading YAML frontmatter block and splits the Markdown body with accurate file line ranges.
    public static func splitDocument(_ rawDocument: String) -> [RuleUnit] {
        let parsed = FrontmatterParser.parse(rawDocument, redactSecrets: false)
        return split(parsed.body, startingAtLine: parsed.bodyStartLine)
    }

    /// Splits a Markdown body into `RuleUnit` items using `startingAtLine` as the 1-based line offset.
    public static func split(_ markdown: String, startingAtLine: Int = 1) -> [RuleUnit] {
        let rawLines = splitLinesPreservingEmpty(markdown)
        var units: [RuleUnit] = []
        var headingStack: [(level: Int, title: String)] = []

        var activeFence: (char: Character, length: Int)?
        var pendingKind: RuleUnit.Kind?
        var pendingLines: [String] = []
        var pendingStartLine = startingAtLine
        var pendingEndLine = startingAtLine
        var pendingHeadings: [String] = []

        func flushPending() {
            guard let kind = pendingKind, !pendingLines.isEmpty else {
                pendingKind = nil
                pendingLines = []
                return
            }

            let combined = pendingLines.joined(separator: "\n")
            let range = pendingStartLine...pendingEndLine

            if kind == .paragraph {
                let sentences = splitParagraphIntoSentences(combined)
                for sentence in sentences {
                    let norm = normalize(sentence)
                    if !norm.isEmpty {
                        units.append(
                            RuleUnit(
                                kind: .paragraph,
                                headingPath: pendingHeadings,
                                rawText: sentence,
                                normalizedText: norm,
                                lineRange: range
                            )
                        )
                    }
                }
            } else {
                let norm = normalize(combined)
                if !norm.isEmpty {
                    units.append(
                        RuleUnit(
                            kind: kind,
                            headingPath: pendingHeadings,
                            rawText: combined,
                            normalizedText: norm,
                            lineRange: range
                        )
                    )
                }
            }

            pendingKind = nil
            pendingLines = []
        }

        for (offset, line) in rawLines.enumerated() {
            let lineNumber = startingAtLine + offset
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = activeFence {
                if isClosingFence(trimmed, matching: fence) {
                    activeFence = nil
                }
                continue
            }

            if let openedFence = detectOpeningFence(trimmed) {
                flushPending()
                activeFence = openedFence
                continue
            }

            if trimmed.isEmpty || isHorizontalRule(trimmed) {
                flushPending()
                continue
            }

            if let heading = parseATXHeading(trimmed) {
                flushPending()
                while let last = headingStack.last, last.level >= heading.level {
                    headingStack.removeLast()
                }
                headingStack.append(heading)
                continue
            }

            let currentHeadings = headingStack.map(\.title)

            if let bulletContent = stripBulletPrefix(from: trimmed) {
                flushPending()
                pendingKind = .bullet
                pendingLines = [bulletContent]
                pendingStartLine = lineNumber
                pendingEndLine = lineNumber
                pendingHeadings = currentHeadings
                continue
            }

            if let numberedContent = stripNumberedPrefix(from: trimmed) {
                flushPending()
                pendingKind = .numbered
                pendingLines = [numberedContent]
                pendingStartLine = lineNumber
                pendingEndLine = lineNumber
                pendingHeadings = currentHeadings
                continue
            }

            // Continuation of an active bullet/numbered item (indented line) or active paragraph
            let hasLeadingIndent = line.hasPrefix("  ") || line.hasPrefix("\t")
            if let active = pendingKind {
                if (active == .bullet || active == .numbered) && hasLeadingIndent {
                    pendingLines.append(trimmed)
                    pendingEndLine = lineNumber
                    continue
                }
                if active == .paragraph {
                    pendingLines.append(trimmed)
                    pendingEndLine = lineNumber
                    continue
                }
                flushPending()
            }

            pendingKind = .paragraph
            pendingLines = [trimmed]
            pendingStartLine = lineNumber
            pendingEndLine = lineNumber
            pendingHeadings = currentHeadings
        }

        flushPending()
        return units
    }

    /// Strips Markdown formatting, lowercases, and collapses whitespace into canonical prose text.
    public static func normalize(_ text: String) -> String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let strippedLines: [String] = lines.map { rawLine in
            var s = rawLine.trimmingCharacters(in: .whitespaces)
            while s.hasPrefix(">") {
                s = s.dropFirst().trimmingCharacters(in: .whitespaces)
            }
            if let bulletRest = stripBulletPrefix(from: s) {
                s = bulletRest
            } else if let numRest = stripNumberedPrefix(from: s) {
                s = numRest
            }
            s = stripTaskCheckbox(from: s)
            return s
        }

        let joined = strippedLines.joined(separator: " ")
        let inlineStripped = stripInlineMarkdownPreservingCodeSpans(joined)
        let lowercased = inlineStripped.lowercased()

        let collapsed =
            lowercased
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed
    }

    // MARK: - Block & Line Classifiers

    private static func splitLinesPreservingEmpty(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines: [String] = []
        var cursor = text.startIndex

        while cursor < text.endIndex {
            var lineEnd = cursor
            while lineEnd < text.endIndex && text[lineEnd] != "\n" {
                lineEnd = text.index(after: lineEnd)
            }
            var contentEnd = lineEnd
            if contentEnd > cursor && text[text.index(before: contentEnd)] == "\r" {
                contentEnd = text.index(before: contentEnd)
            }
            lines.append(String(text[cursor..<contentEnd]))
            if lineEnd < text.endIndex {
                cursor = text.index(after: lineEnd)
            } else {
                break
            }
        }
        return lines
    }

    private static func detectOpeningFence(_ trimmed: String) -> (char: Character, length: Int)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        if first == "`" {
            let info = trimmed.dropFirst(count)
            if info.contains("`") {
                return nil
            }
        }
        return (first, count)
    }

    private static func isClosingFence(_ trimmed: String, matching fence: (char: Character, length: Int)) -> Bool {
        let count = trimmed.prefix { $0 == fence.char }.count
        guard count >= fence.length else { return false }
        return trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, first == "-" || first == "*" || first == "_" else {
            return false
        }
        let nonSpace = trimmed.filter { !$0.isWhitespace }
        return nonSpace.count >= 3 && nonSpace.allSatisfy { $0 == first }
    }

    private static func parseATXHeading(_ trimmed: String) -> (level: Int, title: String)? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let remainder = trimmed.dropFirst(hashes)
        guard remainder.isEmpty || remainder.first?.isWhitespace == true else { return nil }
        var title = remainder.trimmingCharacters(in: .whitespaces)
        while title.hasSuffix("#") {
            let candidate = String(title.dropLast())
            if candidate.isEmpty || candidate.last?.isWhitespace == true {
                title = candidate.trimmingCharacters(in: .whitespaces)
            } else {
                break
            }
        }
        let cleanTitle = stripInlineMarkdownPreservingCodeSpans(title)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return (hashes, cleanTitle)
    }

    private static func stripBulletPrefix(from trimmed: String) -> String? {
        for marker in ["- ", "* ", "+ ", "-\t", "*\t", "+\t"] {
            if trimmed.hasPrefix(marker) {
                let rest = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                return stripTaskCheckbox(from: rest)
            }
        }
        return nil
    }

    private static func stripNumberedPrefix(from trimmed: String) -> String? {
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let afterDigits = trimmed.dropFirst(digits.count)
        guard let punct = afterDigits.first, punct == "." || punct == ")" else { return nil }
        let afterPunct = afterDigits.dropFirst()
        guard afterPunct.first?.isWhitespace == true else { return nil }
        return stripTaskCheckbox(from: afterPunct.trimmingCharacters(in: .whitespaces))
    }

    private static func stripTaskCheckbox(from text: String) -> String {
        for prefix in ["[ ] ", "[x] ", "[X] "] {
            if text.hasPrefix(prefix) {
                return String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return text
    }

    // MARK: - Sentence Splitting & Inline Markdown Stripping

    private static func splitParagraphIntoSentences(_ paragraph: String) -> [String] {
        let flattened =
            paragraph
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")

        let chars = Array(flattened)
        var sentences: [String] = []
        var sentenceStart = 0
        var idx = 0
        var parenDepth = 0
        var bracketDepth = 0
        var inBackticks = false

        while idx < chars.count {
            let ch = chars[idx]
            if ch == "`" {
                inBackticks.toggle()
                idx += 1
                continue
            }
            if !inBackticks {
                if ch == "(" {
                    parenDepth += 1
                } else if ch == ")" && parenDepth > 0 {
                    parenDepth -= 1
                } else if ch == "[" {
                    bracketDepth += 1
                } else if ch == "]" && bracketDepth > 0 {
                    bracketDepth -= 1
                } else if parenDepth == 0 && bracketDepth == 0
                    && (ch == "." || ch == "!" || ch == "?")
                {
                    if isSentenceBoundary(chars: chars, at: idx) {
                        var endIdx = idx + 1
                        while endIdx < chars.count && (chars[endIdx] == "\"" || chars[endIdx] == "'") {
                            endIdx += 1
                        }
                        let slice = String(chars[sentenceStart..<endIdx])
                            .trimmingCharacters(in: .whitespaces)
                        if !slice.isEmpty {
                            sentences.append(slice)
                        }
                        idx = endIdx
                        while idx < chars.count && chars[idx].isWhitespace {
                            idx += 1
                        }
                        sentenceStart = idx
                        continue
                    }
                }
            }
            idx += 1
        }

        if sentenceStart < chars.count {
            let tail = String(chars[sentenceStart..<chars.count]).trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty {
                sentences.append(tail)
            }
        }

        return sentences
    }

    private static func isSentenceBoundary(chars: [Character], at punctIdx: Int) -> Bool {
        let punct = chars[punctIdx]
        var nextIdx = punctIdx + 1
        while nextIdx < chars.count && (chars[nextIdx] == "\"" || chars[nextIdx] == "'") {
            nextIdx += 1
        }
        guard nextIdx < chars.count, chars[nextIdx].isWhitespace else {
            return false
        }

        if punct == "." {
            // Do not split decimal/version numbers like `1.0`
            if punctIdx > 0 && chars[punctIdx - 1].isNumber
                && punctIdx + 1 < chars.count && chars[punctIdx + 1].isNumber
            {
                return false
            }

            // Do not split known abbreviations like `e.g.` or `i.e.`
            var wordStart = punctIdx
            while wordStart > 0 && !chars[wordStart - 1].isWhitespace && chars[wordStart - 1] != "(" {
                wordStart -= 1
            }
            let wordWithDot = String(chars[wordStart...punctIdx]).lowercased()
            if nonSentenceAbbreviations.contains(wordWithDot) {
                return false
            }
        }

        var lookahead = nextIdx
        while lookahead < chars.count && chars[lookahead].isWhitespace {
            lookahead += 1
        }
        while lookahead < chars.count
            && (chars[lookahead] == "`" || chars[lookahead] == "*" || chars[lookahead] == "_"
                || chars[lookahead] == "\"" || chars[lookahead] == "'")
        {
            lookahead += 1
        }
        guard lookahead < chars.count else { return false }
        let nextStarter = chars[lookahead]
        return nextStarter.isUppercase || nextStarter.isNumber || nextStarter == "["
    }

    private static func stripInlineMarkdownPreservingCodeSpans(_ input: String) -> String {
        // Segment into literal code-span segments vs markdown prose segments.
        let chars = Array(input)
        var result = ""
        var proseBuffer = ""
        var i = 0

        func flushProse() {
            guard !proseBuffer.isEmpty else { return }
            result.append(stripMarkdownFromProseSegment(proseBuffer))
            proseBuffer = ""
        }

        while i < chars.count {
            if chars[i] == "`" {
                var tickCount = 0
                while i + tickCount < chars.count && chars[i + tickCount] == "`" {
                    tickCount += 1
                }
                if let closeStart = findClosingTicks(in: chars, from: i + tickCount, count: tickCount) {
                    flushProse()
                    let codeContent = String(chars[(i + tickCount)..<closeStart])
                    result.append(codeContent)
                    i = closeStart + tickCount
                    continue
                }
            }
            proseBuffer.append(chars[i])
            i += 1
        }

        flushProse()
        return result
    }

    private static func findClosingTicks(in chars: [Character], from start: Int, count: Int) -> Int? {
        var idx = start
        while idx + count <= chars.count {
            if chars[idx] == "`" {
                var run = 0
                while idx + run < chars.count && chars[idx + run] == "`" {
                    run += 1
                }
                if run == count {
                    return idx
                }
                idx += run
            } else {
                idx += 1
            }
        }
        return nil
    }

    private static func stripMarkdownFromProseSegment(_ prose: String) -> String {
        // 1. Unwrap images `![alt](url)` and links `[label](url)` -> `alt` / `label`
        let chars = Array(prose)
        var linkUnwrapped = ""
        var idx = 0

        while idx < chars.count {
            if chars[idx] == "!" && idx + 1 < chars.count && chars[idx + 1] == "[" {
                if let (label, afterParen) = parseMarkdownLink(in: chars, openBracketIndex: idx + 1) {
                    linkUnwrapped.append(label)
                    idx = afterParen
                    continue
                }
            } else if chars[idx] == "[" {
                if let (label, afterParen) = parseMarkdownLink(in: chars, openBracketIndex: idx) {
                    linkUnwrapped.append(label)
                    idx = afterParen
                    continue
                }
            }
            linkUnwrapped.append(chars[idx])
            idx += 1
        }

        // 2. Strip emphasis delimiters (`**`, `__`, `~~`, `*`, `_`) when acting as formatting wrappers.
        var cleaned =
            linkUnwrapped
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "~~", with: "")

        cleaned = stripSingleEmphasisDelimiters(cleaned)
        return cleaned
    }

    private static func parseMarkdownLink(
        in chars: [Character],
        openBracketIndex: Int
    ) -> (label: String, nextIndex: Int)? {
        var closeBracket = openBracketIndex + 1
        var depth = 1
        while closeBracket < chars.count {
            if chars[closeBracket] == "[" {
                depth += 1
            } else if chars[closeBracket] == "]" {
                depth -= 1
                if depth == 0 {
                    break
                }
            }
            closeBracket += 1
        }
        guard closeBracket < chars.count, closeBracket + 1 < chars.count, chars[closeBracket + 1] == "(" else {
            return nil
        }

        var closeParen = closeBracket + 2
        var parenDepth = 1
        while closeParen < chars.count {
            if chars[closeParen] == "(" {
                parenDepth += 1
            } else if chars[closeParen] == ")" {
                parenDepth -= 1
                if parenDepth == 0 {
                    let label = String(chars[(openBracketIndex + 1)..<closeBracket])
                    return (label, closeParen + 1)
                }
            }
            closeParen += 1
        }
        return nil
    }

    private static func stripSingleEmphasisDelimiters(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        for idx in chars.indices {
            let ch = chars[idx]
            if ch == "*" || ch == "_" {
                let prev = idx > 0 ? chars[idx - 1] : nil
                let next = idx + 1 < chars.count ? chars[idx + 1] : nil
                let prevIsWord = prev.map { $0.isLetter || $0.isNumber || $0 == "/" || $0 == "." } ?? false
                let nextIsWord = next.map { $0.isLetter || $0.isNumber || $0 == "/" || $0 == "." } ?? false

                // Preserve snake_case (`foo_bar`) and glob wildcards (`*.swift`, `Sources/*`)
                if ch == "_" && prevIsWord && nextIsWord {
                    out.append(ch)
                    continue
                }
                if ch == "*" && (next == "." || next == "/" || prev == "/") {
                    out.append(ch)
                    continue
                }
                if prevIsWord || nextIsWord {
                    continue
                }
            }
            out.append(ch)
        }
        return out
    }
}
