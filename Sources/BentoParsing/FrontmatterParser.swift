import BentoCore
import Foundation
import Yams

/// YAML frontmatter parser backed by `Yams` with unquoted-glob recovery and secret redaction.
public enum FrontmatterParser {
    /// Parses optional YAML frontmatter and body from a Markdown string.
    public static func parse(
        _ text: String,
        location: SourceLocation? = nil,
        redactSecrets: Bool = true
    ) -> FrontmatterDocument {
        let cleaned = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let lineSpans = collectLineSpans(in: cleaned)
        guard let firstLine = lineSpans.first else {
            return FrontmatterDocument(frontmatter: nil, body: cleaned, bodyStartLine: 1)
        }

        let firstTrimmed = cleaned[firstLine.contentRange].trimmingCharacters(in: .whitespaces)
        guard firstTrimmed == "---" else {
            return FrontmatterDocument(frontmatter: nil, body: cleaned, bodyStartLine: 1)
        }

        var closingLineIndex: Int?
        for idx in 1..<lineSpans.count {
            let candidate = cleaned[lineSpans[idx].contentRange].trimmingCharacters(in: .whitespaces)
            if candidate == "---" || candidate == "..." {
                closingLineIndex = idx
                break
            }
        }

        guard let closeIdx = closingLineIndex else {
            let diag = Diagnostic(
                code: "frontmatter.unclosed",
                severity: .warning,
                message: "Unclosed YAML frontmatter block; expected closing '---'",
                location: withLineRange(location, 1...1)
            )
            return FrontmatterDocument(
                frontmatter: nil,
                body: cleaned,
                bodyStartLine: 1,
                diagnostics: [diag]
            )
        }

        let yamlStart = firstLine.fullRange.upperBound
        let yamlEnd = lineSpans[closeIdx].fullRange.lowerBound
        let yamlBlock = String(cleaned[yamlStart..<yamlEnd])

        let bodyStart = lineSpans[closeIdx].fullRange.upperBound
        let body = String(cleaned[bodyStart..<cleaned.endIndex])
        let bodyStartLine = closeIdx + 2
        let frontmatterRange = 1...(closeIdx + 1)

        if yamlBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return FrontmatterDocument(
                frontmatter: [:],
                body: body,
                bodyStartLine: bodyStartLine
            )
        }

        do {
            let rootNode = try composeYAMLWithGlobFallback(yamlBlock)
            guard let node = rootNode else {
                return FrontmatterDocument(
                    frontmatter: [:],
                    body: body,
                    bodyStartLine: bodyStartLine
                )
            }
            guard case .mapping(let mapping) = node else {
                let diag = Diagnostic(
                    code: "frontmatter.notMapping",
                    severity: .warning,
                    message: "Expected YAML frontmatter root to be a key-value mapping",
                    location: withLineRange(location, frontmatterRange)
                )
                return FrontmatterDocument(
                    frontmatter: nil,
                    body: body,
                    bodyStartLine: bodyStartLine,
                    diagnostics: [diag]
                )
            }

            let rawMap = convertMapping(mapping)
            let finalMap = redactSecrets ? SecretRedactor.redact(rawMap) : rawMap
            return FrontmatterDocument(
                frontmatter: finalMap,
                body: body,
                bodyStartLine: bodyStartLine
            )
        } catch {
            let diag = Diagnostic(
                code: "frontmatter.malformed",
                severity: .warning,
                message: "Malformed YAML frontmatter: \(error)",
                location: withLineRange(location, frontmatterRange)
            )
            return FrontmatterDocument(
                frontmatter: nil,
                body: body,
                bodyStartLine: bodyStartLine,
                diagnostics: [diag]
            )
        }
    }

    /// Parses optional YAML frontmatter and body from UTF-8 bytes.
    public static func parse(
        _ data: Data,
        location: SourceLocation? = nil,
        redactSecrets: Bool = true
    ) throws -> FrontmatterDocument {
        guard let text = String(data: data, encoding: .utf8) else {
            throw BentoParsingError.invalidUTF8
        }
        return parse(text, location: location, redactSecrets: redactSecrets)
    }

    // MARK: - Private Helpers

    private struct LineSpan {
        let contentRange: Range<String.Index>
        let fullRange: Range<String.Index>
    }

    private static func collectLineSpans(in text: String) -> [LineSpan] {
        var spans: [LineSpan] = []
        var cursor = text.startIndex

        while cursor < text.endIndex {
            var lineEnd = cursor
            while lineEnd < text.endIndex && text[lineEnd] != "\n" {
                lineEnd = text.index(after: lineEnd)
            }

            var contentEnd = lineEnd
            if contentEnd > cursor {
                let beforeEnd = text.index(before: contentEnd)
                if text[beforeEnd] == "\r" {
                    contentEnd = beforeEnd
                }
            }

            let fullEnd = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
            spans.append(LineSpan(contentRange: cursor..<contentEnd, fullRange: cursor..<fullEnd))
            cursor = fullEnd
        }

        return spans
    }

    private static func composeYAMLWithGlobFallback(_ yaml: String) throws -> Node? {
        do {
            return try Yams.compose(yaml: yaml)
        } catch {
            let sanitized = quoteLeadingAsteriskScalars(in: yaml)
            guard sanitized != yaml else {
                throw error
            }
            return try Yams.compose(yaml: sanitized)
        }
    }

    /// Quotes unquoted YAML scalar values that begin with `*` (common in Cursor `.mdc` `globs: *.swift`).
    private static func quoteLeadingAsteriskScalars(in yaml: String) -> String {
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false)
        var rewritten: [String] = []
        rewritten.reserveCapacity(lines.count)

        for rawLine in lines {
            var line = String(rawLine)
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            if let colonIndex = line.firstIndex(of: ":") {
                let keyPart = line[..<colonIndex]
                let keyTrimmed = keyPart.trimmingCharacters(in: .whitespaces)
                if !keyTrimmed.isEmpty && !keyTrimmed.hasPrefix("#") && !keyTrimmed.hasPrefix("-") {
                    let afterColon = line[line.index(after: colonIndex)...]
                    let valueTrimmed = afterColon.trimmingCharacters(in: .whitespaces)
                    if valueTrimmed.hasPrefix("*") {
                        let escaped =
                            valueTrimmed
                            .replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"")
                        rewritten.append("\(keyPart): \"\(escaped)\"")
                        continue
                    }
                }
            }
            rewritten.append(line)
        }

        return rewritten.joined(separator: "\n")
    }

    private static func convertMapping(_ mapping: Node.Mapping) -> [String: JSONValue] {
        var dict: [String: JSONValue] = [:]
        for (keyNode, valueNode) in mapping {
            let key = keyNode.string ?? scalarText(from: keyNode)
            dict[key] = convertNode(valueNode)
        }
        return dict
    }

    private static func convertNode(_ node: Node) -> JSONValue {
        switch node {
        case .scalar(let scalar):
            return convertScalar(scalar, node: node)
        case .sequence(let sequence):
            return .array(sequence.map(convertNode))
        case .mapping(let mapping):
            return .object(convertMapping(mapping))
        case .alias:
            return .null
        }
    }

    private static func convertScalar(_ scalar: Node.Scalar, node: Node) -> JSONValue {
        let isUnquoted = scalar.style == .any || scalar.style == .plain
        if isUnquoted {
            if node.null != nil || scalar.string.isEmpty || scalar.string == "~" || scalar.string == "null" {
                return .null
            }
            if let boolVal = Bool.construct(from: scalar) {
                return .bool(boolVal)
            }
            if let intVal = Int.construct(from: scalar) {
                return .int(Int64(intVal))
            }
            if let doubleVal = Double.construct(from: scalar), doubleVal.isFinite {
                return .double(doubleVal)
            }
        }
        return .string(scalar.string)
    }

    private static func scalarText(from node: Node) -> String {
        switch node {
        case .scalar(let s):
            return s.string
        default:
            return String(describing: node)
        }
    }

    private static func withLineRange(
        _ location: SourceLocation?,
        _ range: ClosedRange<Int>
    ) -> SourceLocation? {
        guard var copy = location else { return nil }
        copy.lineRange = range
        return copy
    }
}
