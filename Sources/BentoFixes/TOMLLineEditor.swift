import BentoCore
import BentoParsing
import Foundation

/// Format-preserving TOML line/section editor (`PLAN.md` §6.6).
///
/// Updates or inserts boolean keys inside `[section.path]` tables while keeping
/// full-line `#` comments, inline `#` comments, blank lines, and unrelated tables byte-identical.
public enum TOMLLineEditor {
    /// Sets or inserts `key = true|false` inside `[sectionPath]`.
    public static func setBooleanInSection(
        in text: String,
        sectionPath: [String],
        key: String,
        value: Bool
    ) throws -> String {
        guard !sectionPath.isEmpty else {
            throw BentoFixesError.malformedConfiguration(path: nil, details: "Empty TOML sectionPath")
        }

        // Validate input TOML first so malformed files are never corrupted further.
        _ = try validateTOML(text)

        let lineEnding = text.contains("\r\n") ? "\r\n" : "\n"
        let hasTrailingNewline = text.hasSuffix("\n")
        var lines = splitPreservingEmptyLines(text)
        if hasTrailingNewline && lines.last == "" {
            lines.removeLast()
        }

        let sections = scanSections(in: lines)
        let boolToken = value ? "true" : "false"

        if let target = sections.last(where: { $0.path == sectionPath }) {
            let bodyRange = (target.headerLine + 1)..<target.endLine

            // 1. Check if `key = ...` already exists inside this section body.
            for lineIdx in bodyRange {
                if let replaced = replaceBooleanAssignment(
                    in: lines[lineIdx],
                    matchingKey: key,
                    newToken: boolToken
                ) {
                    lines[lineIdx] = replaced
                    let joined = joinLines(lines, separator: lineEnding, trailingNewline: hasTrailingNewline)
                    _ = try validateTOML(joined)
                    return joined
                }
            }

            // 2. Otherwise insert `key = <bool>` after the last non-blank line in the section.
            var insertAfter = target.headerLine
            var detectedIndent = ""
            for lineIdx in bodyRange {
                let trimmed = lines[lineIdx].trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    insertAfter = lineIdx
                    if !trimmed.hasPrefix("#") && detectedIndent.isEmpty {
                        detectedIndent = leadingWhitespace(of: lines[lineIdx])
                    }
                }
            }

            let formattedKey = formatTOMLKeySegment(key)
            lines.insert("\(detectedIndent)\(formattedKey) = \(boolToken)", at: insertAfter + 1)
            let joined = joinLines(lines, separator: lineEnding, trailingNewline: hasTrailingNewline)
            _ = try validateTOML(joined)
            return joined
        }

        // 3. Fallback: inline table assignment inside parent section (e.g. `[mcp_servers]` with `github = { ... }`).
        let parentPath = Array(sectionPath.dropLast())
        let tableKey = sectionPath[sectionPath.count - 1]
        let searchRange: Range<Int>
        if parentPath.isEmpty {
            let firstSectionLine = sections.first?.headerLine ?? lines.count
            searchRange = 0..<firstSectionLine
        } else if let parentSection = sections.last(where: { $0.path == parentPath }) {
            searchRange = (parentSection.headerLine + 1)..<parentSection.endLine
        } else {
            throw BentoFixesError.targetNotFound(
                "TOML section '[\(sectionPath.joined(separator: "."))]' not found"
            )
        }

        for lineIdx in searchRange {
            if let updatedLine = updateInlineTableBoolean(
                in: lines[lineIdx],
                tableKey: tableKey,
                propertyKey: key,
                newToken: boolToken
            ) {
                lines[lineIdx] = updatedLine
                let joined = joinLines(lines, separator: lineEnding, trailingNewline: hasTrailingNewline)
                _ = try validateTOML(joined)
                return joined
            }
        }

        throw BentoFixesError.targetNotFound(
            "TOML section '[\(sectionPath.joined(separator: "."))]' not found"
        )
    }

    // MARK: - Section & Line Parsing

    private struct SectionSpan {
        var path: [String]
        var isArrayOfTables: Bool
        var headerLine: Int
        var endLine: Int
    }

    private static func scanSections(in lines: [String]) -> [SectionSpan] {
        var headers: [(path: [String], isArray: Bool, line: Int)] = []
        var multilineDelimiter: String?

        for (idx, line) in lines.enumerated() {
            if let active = multilineDelimiter {
                if lineClosesMultiline(line, delimiter: active) {
                    multilineDelimiter = nil
                }
                continue
            }

            let codePart = stripTOMLComment(from: line, enteredMultiline: &multilineDelimiter)
            let trimmed = codePart.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[") else { continue }

            if trimmed.hasPrefix("[[") && trimmed.hasSuffix("]]") && trimmed.count >= 5 {
                let inner = String(trimmed.dropFirst(2).dropLast(2))
                if let parsed = parseDottedKeyPath(inner) {
                    headers.append((parsed, true, idx))
                }
            } else if !trimmed.hasPrefix("[["), trimmed.hasSuffix("]"), trimmed.count >= 3 {
                let inner = String(trimmed.dropFirst().dropLast())
                if let parsed = parseDottedKeyPath(inner) {
                    headers.append((parsed, false, idx))
                }
            }
        }

        var spans: [SectionSpan] = []
        for (i, header) in headers.enumerated() {
            let endLine = (i + 1 < headers.count) ? headers[i + 1].line : lines.count
            spans.append(
                SectionSpan(
                    path: header.path,
                    isArrayOfTables: header.isArray,
                    headerLine: header.line,
                    endLine: endLine
                )
            )
        }
        return spans
    }

    private static func replaceBooleanAssignment(
        in line: String,
        matchingKey targetKey: String,
        newToken: String
    ) -> String? {
        var dummyMultiline: String?
        let codePart = stripTOMLComment(from: line, enteredMultiline: &dummyMultiline)
        let commentSuffix = String(line.dropFirst(codePart.count))

        guard let eqIndex = firstUnquotedCharacter("=", in: codePart) else {
            return nil
        }

        let lhs = String(codePart[..<eqIndex]).trimmingCharacters(in: .whitespaces)
        guard let keys = parseDottedKeyPath(lhs), keys == [targetKey] else {
            return nil
        }

        let afterEqStart = codePart.index(after: eqIndex)
        let rhsRaw = String(codePart[afterEqStart...])
        let leadingWS = leadingWhitespace(of: rhsRaw)
        let trailingWS = trailingWhitespace(of: rhsRaw)
        let valueCore = rhsRaw.trimmingCharacters(in: .whitespaces)
        guard valueCore == "true" || valueCore == "false" else {
            return nil
        }

        let prefix = String(codePart[...eqIndex])
        return "\(prefix)\(leadingWS)\(newToken)\(trailingWS)\(commentSuffix)"
    }

    private static func updateInlineTableBoolean(
        in line: String,
        tableKey: String,
        propertyKey: String,
        newToken: String
    ) -> String? {
        var dummyMultiline: String?
        let codePart = stripTOMLComment(from: line, enteredMultiline: &dummyMultiline)
        let commentSuffix = String(line.dropFirst(codePart.count))

        guard let eqIndex = firstUnquotedCharacter("=", in: codePart) else {
            return nil
        }
        let lhs = String(codePart[..<eqIndex]).trimmingCharacters(in: .whitespaces)
        guard let keys = parseDottedKeyPath(lhs), keys == [tableKey] else {
            return nil
        }

        let afterEq = String(codePart[codePart.index(after: eqIndex)...])
        guard
            let openBrace = firstUnquotedCharacter("{", in: afterEq),
            let closeBrace = lastUnquotedCharacter("}", in: afterEq),
            openBrace < closeBrace
        else {
            return nil
        }

        let innerStart = afterEq.index(after: openBrace)
        let inner = String(afterEq[innerStart..<closeBrace])
        let formattedProp = formatTOMLKeySegment(propertyKey)

        // Split inline table top-level entries on `,` outside quotes/brackets/braces.
        var entries = splitTopLevelInlineEntries(inner)
        var updatedExisting = false
        for i in entries.indices {
            if let eq = firstUnquotedCharacter("=", in: entries[i]) {
                let entryLHS = String(entries[i][..<eq]).trimmingCharacters(in: .whitespaces)
                if parseDottedKeyPath(entryLHS) == [propertyKey] {
                    let prefix = String(entries[i][...eq])
                    entries[i] = "\(prefix) \(newToken)"
                    updatedExisting = true
                    break
                }
            }
        }

        let newInner: String
        if updatedExisting {
            newInner = entries.joined(separator: ",")
        } else if inner.trimmingCharacters(in: .whitespaces).isEmpty {
            newInner = " \(formattedProp) = \(newToken) "
        } else {
            let trimmedRight = inner.replacingOccurrences(
                of: "\\s+$",
                with: "",
                options: .regularExpression
            )
            let sep = trimmedRight.hasSuffix(",") ? " " : ", "
            newInner = "\(trimmedRight)\(sep)\(formattedProp) = \(newToken) "
        }

        let head = String(codePart[...eqIndex]) + String(afterEq[...openBrace])
        let tail = String(afterEq[closeBrace...])
        return "\(head)\(newInner)\(tail)\(commentSuffix)"
    }

    private static func splitTopLevelInlineEntries(_ inner: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var depth = 0

        for ch in inner {
            if let q = quote {
                current.append(ch)
                if q == "\"" && escaped {
                    escaped = false
                } else if q == "\"" && ch == "\\" {
                    escaped = true
                } else if ch == q {
                    quote = nil
                }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                current.append(ch)
            } else if ch == "[" || ch == "{" {
                depth += 1
                current.append(ch)
            } else if ch == "]" || ch == "}" {
                depth = max(0, depth - 1)
                current.append(ch)
            } else if ch == "," && depth == 0 {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        result.append(current)
        return result
    }

    private static func parseDottedKeyPath(_ raw: String) -> [String]? {
        let chars = Array(raw)
        var idx = 0
        var segments: [String] = []

        while idx < chars.count {
            while idx < chars.count && chars[idx].isWhitespace {
                idx += 1
            }
            if idx >= chars.count { break }

            if chars[idx] == "\"" {
                idx += 1
                var value = ""
                var closed = false
                while idx < chars.count {
                    let ch = chars[idx]
                    if ch == "\\" && idx + 1 < chars.count {
                        let next = chars[idx + 1]
                        switch next {
                        case "\"", "\\":
                            value.append(next)
                        case "n":
                            value.append("\n")
                        case "t":
                            value.append("\t")
                        case "r":
                            value.append("\r")
                        default:
                            value.append(next)
                        }
                        idx += 2
                        continue
                    }
                    if ch == "\"" {
                        idx += 1
                        closed = true
                        break
                    }
                    value.append(ch)
                    idx += 1
                }
                guard closed else { return nil }
                segments.append(value)
            } else if chars[idx] == "'" {
                idx += 1
                var value = ""
                var closed = false
                while idx < chars.count {
                    if chars[idx] == "'" {
                        idx += 1
                        closed = true
                        break
                    }
                    value.append(chars[idx])
                    idx += 1
                }
                guard closed else { return nil }
                segments.append(value)
            } else {
                let start = idx
                while idx < chars.count {
                    let ch = chars[idx]
                    if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-") {
                        idx += 1
                    } else {
                        break
                    }
                }
                guard idx > start else { return nil }
                segments.append(String(chars[start..<idx]))
            }

            while idx < chars.count && chars[idx].isWhitespace {
                idx += 1
            }
            if idx < chars.count {
                guard chars[idx] == "." else { return nil }
                idx += 1
            }
        }

        return segments.isEmpty ? nil : segments
    }

    private static func formatTOMLKeySegment(_ key: String) -> String {
        let isBare =
            !key.isEmpty
            && key.allSatisfy { ch in
                ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-")
            }
        if isBare {
            return key
        }
        let escaped =
            key
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func stripTOMLComment(
        from line: String,
        enteredMultiline: inout String?
    ) -> String {
        let chars = Array(line)
        var idx = 0
        var quote: Character?
        var escaped = false

        while idx < chars.count {
            let ch = chars[idx]
            if let q = quote {
                if q == "\"" && escaped {
                    escaped = false
                    idx += 1
                    continue
                }
                if q == "\"" && ch == "\\" {
                    escaped = true
                    idx += 1
                    continue
                }
                if ch == q {
                    quote = nil
                }
                idx += 1
                continue
            }

            if idx + 2 < chars.count
                && ((ch == "\"" && chars[idx + 1] == "\"" && chars[idx + 2] == "\"")
                    || (ch == "'" && chars[idx + 1] == "'" && chars[idx + 2] == "'"))
            {
                let delim = String(repeating: String(ch), count: 3)
                idx += 3
                if let closeOffset = findSubstring(delim, in: chars, from: idx) {
                    idx = closeOffset + 3
                    continue
                } else {
                    enteredMultiline = delim
                    return line
                }
            }

            if ch == "\"" || ch == "'" {
                quote = ch
                idx += 1
                continue
            }

            if ch == "#" {
                return String(chars[0..<idx])
            }

            idx += 1
        }
        return line
    }

    private static func lineClosesMultiline(_ line: String, delimiter: String) -> Bool {
        line.contains(delimiter)
    }

    private static func findSubstring(_ target: String, in chars: [Character], from start: Int) -> Int? {
        let tChars = Array(target)
        guard start + tChars.count <= chars.count else { return nil }
        for i in start...(chars.count - tChars.count) where Array(chars[i..<(i + tChars.count)]) == tChars {
            return i
        }
        return nil
    }

    private static func firstUnquotedCharacter(_ target: Character, in text: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            if let q = quote {
                if q == "\"" && escaped {
                    escaped = false
                } else if q == "\"" && ch == "\\" {
                    escaped = true
                } else if ch == q {
                    quote = nil
                }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == target {
                return idx
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    private static func lastUnquotedCharacter(_ target: Character, in text: String) -> String.Index? {
        var match: String.Index?
        var quote: Character?
        var escaped = false
        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            if let q = quote {
                if q == "\"" && escaped {
                    escaped = false
                } else if q == "\"" && ch == "\\" {
                    escaped = true
                } else if ch == q {
                    quote = nil
                }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == target {
                match = idx
            }
            idx = text.index(after: idx)
        }
        return match
    }

    private static func leadingWhitespace(of text: String) -> String {
        var end = text.startIndex
        while end < text.endIndex && (text[end] == " " || text[end] == "\t") {
            end = text.index(after: end)
        }
        return String(text[..<end])
    }

    private static func trailingWhitespace(of text: String) -> String {
        var start = text.endIndex
        while start > text.startIndex {
            let prev = text.index(before: start)
            if text[prev] == " " || text[prev] == "\t" {
                start = prev
            } else {
                break
            }
        }
        return String(text[start...])
    }

    private static func splitPreservingEmptyLines(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.components(separatedBy: "\n")
    }

    private static func joinLines(
        _ lines: [String],
        separator: String,
        trailingNewline: Bool
    ) -> String {
        let core = lines.joined(separator: separator)
        return trailingNewline ? (core + separator) : core
    }

    private static func validateTOML(_ text: String) throws -> [String: JSONValue] {
        do {
            return try TOMLParser.parseObject(text, redactSecrets: false)
        } catch {
            throw BentoFixesError.malformedConfiguration(
                path: nil,
                details: String(describing: error)
            )
        }
    }
}
