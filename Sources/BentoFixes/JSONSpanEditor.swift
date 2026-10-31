import BentoCore
import BentoParsing
import Foundation

/// Format-preserving JSON/JSONC span editor (`PLAN.md` §6.6).
///
/// Mutates only targeted byte spans so `//` line comments, `/* */` block comments,
/// trailing commas, key ordering, and surrounding indentation remain intact.
public enum JSONSpanEditor {
    /// Sets or inserts a property at `keyPath` using raw JSON/JSONC `valueLiteral`, creating missing intermediate objects.
    public static func setProperty(
        in text: String,
        keyPath: [String],
        valueLiteral: String
    ) throws -> String {
        guard !keyPath.isEmpty else {
            throw BentoFixesError.malformedConfiguration(path: nil, details: "Empty JSON keyPath")
        }

        let baseText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{\n}\n" : text
        let bytes = Array(baseText.utf8)
        let rootObj = try parseRootObject(bytes: bytes)

        var currentObj = rootObj
        for depth in 0..<(keyPath.count - 1) {
            let segment = keyPath[depth]
            if let existing = currentObj.properties.last(where: { $0.key == segment }) {
                guard case .object(let childObj) = existing.value else {
                    let prefix = keyPath[0...depth].joined(separator: ".")
                    throw BentoFixesError.malformedConfiguration(
                        path: nil,
                        details: "Expected JSON object at '\(prefix)'"
                    )
                }
                currentObj = childObj
            } else {
                let baseIndent = childIndentation(for: currentObj, in: bytes)
                let nestedLiteral = buildNestedObjectLiteral(
                    tailKeys: Array(keyPath[(depth + 1)...]),
                    leafValueLiteral: valueLiteral,
                    baseIndent: baseIndent
                )
                let edits = insertPropertyEdits(
                    into: currentObj,
                    key: segment,
                    valueLiteral: nestedLiteral,
                    bytes: bytes
                )
                let updated = try applyEdits(edits, to: bytes)
                _ = try validateObject(updated)
                return updated
            }
        }

        let leafKey = keyPath[keyPath.count - 1]
        let edits: [ByteEdit]
        if let existing = currentObj.properties.last(where: { $0.key == leafKey }) {
            edits = [
                ByteEdit(
                    range: existing.value.start..<existing.value.end,
                    replacement: Array(valueLiteral.utf8)
                )
            ]
        } else {
            edits = insertPropertyEdits(
                into: currentObj,
                key: leafKey,
                valueLiteral: valueLiteral,
                bytes: bytes
            )
        }

        let updated = try applyEdits(edits, to: bytes)
        _ = try validateObject(updated)
        return updated
    }

    /// Removes the object property at `keyPath` if present, returning the updated JSONC string and the removed raw value snippet.
    public static func removeObjectProperty(
        in text: String,
        keyPath: [String]
    ) throws -> (updated: String, removedRawValue: String?) {
        guard !keyPath.isEmpty else {
            return (text, nil)
        }

        let bytes = Array(text.utf8)
        let rootObj = try parseRootObject(bytes: bytes)

        var currentObj = rootObj
        for depth in 0..<(keyPath.count - 1) {
            let segment = keyPath[depth]
            guard
                let existing = currentObj.properties.last(where: { $0.key == segment }),
                case .object(let childObj) = existing.value
            else {
                return (text, nil)
            }
            currentObj = childObj
        }

        let leafKey = keyPath[keyPath.count - 1]
        guard let idx = currentObj.properties.lastIndex(where: { $0.key == leafKey }) else {
            return (text, nil)
        }

        let prop = currentObj.properties[idx]
        let rawValue = String(decoding: bytes[prop.value.start..<prop.value.end], as: UTF8.self)
        var edits: [ByteEdit] = []

        if isSameLine(currentObj.openBraceOffset, currentObj.closeBraceOffset, in: bytes) {
            if let comma = prop.trailingCommaOffset {
                var delEnd = comma + 1
                while delEnd < currentObj.closeBraceOffset && isHorizontalWhitespace(bytes[delEnd]) {
                    delEnd += 1
                }
                edits.append(ByteEdit(range: prop.keyStart..<delEnd, replacement: []))
            } else if idx > 0, let prevComma = currentObj.properties[idx - 1].trailingCommaOffset {
                edits.append(ByteEdit(range: prevComma..<prop.value.end, replacement: []))
            } else {
                edits.append(ByteEdit(range: prop.keyStart..<prop.value.end, replacement: []))
            }
        } else {
            let keyLineStart = lineStartOffset(of: prop.keyStart, in: bytes)
            let delStart =
                isOnlyHorizontalWhitespace(in: keyLineStart..<prop.keyStart, bytes: bytes)
                ? keyLineStart
                : prop.keyStart
            let baseEnd = prop.trailingCommaOffset.map { $0 + 1 } ?? prop.value.end
            let delEnd = consumeTrailingTriviaOnLine(
                from: baseEnd,
                limit: currentObj.closeBraceOffset,
                bytes: bytes
            )
            edits.append(ByteEdit(range: delStart..<delEnd, replacement: []))

            if prop.trailingCommaOffset == nil,
                idx > 0,
                idx == currentObj.properties.count - 1,
                let prevComma = currentObj.properties[idx - 1].trailingCommaOffset
            {
                edits.append(ByteEdit(range: prevComma..<(prevComma + 1), replacement: []))
            }
        }

        let updated = try applyEdits(edits, to: bytes)
        _ = try validateObject(updated)
        return (updated, rawValue)
    }

    /// Appends `element` to a JSON string array at `keyPath` if not already present, creating the array if absent.
    public static func upsertStringArrayElement(
        in text: String,
        keyPath: [String],
        element: String
    ) throws -> String {
        guard !keyPath.isEmpty else {
            throw BentoFixesError.malformedConfiguration(path: nil, details: "Empty JSON keyPath")
        }

        let baseText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{\n}\n" : text
        let bytes = Array(baseText.utf8)
        let rootObj = try parseRootObject(bytes: bytes)

        guard let node = lookupNode(in: rootObj, keyPath: keyPath) else {
            return try setProperty(
                in: baseText,
                keyPath: keyPath,
                valueLiteral: "[\(encodeJSONString(element))]"
            )
        }

        guard case .array(let arraySpan) = node else {
            throw BentoFixesError.malformedConfiguration(
                path: nil,
                details: "Expected JSON array at '\(keyPath.joined(separator: "."))'"
            )
        }

        for item in arraySpan.elements {
            if case .string(let val, _, _) = item.value, val == element {
                return baseText
            }
        }

        let encodedElem = encodeJSONString(element)
        var edits: [ByteEdit] = []

        if arraySpan.elements.isEmpty {
            if isSameLine(arraySpan.openBracketOffset, arraySpan.closeBracketOffset, in: bytes) {
                edits.append(
                    ByteEdit(
                        range: (arraySpan.openBracketOffset + 1)..<arraySpan.closeBracketOffset,
                        replacement: Array(encodedElem.utf8)
                    )
                )
            } else {
                let closeIndent = lineIndentation(of: arraySpan.closeBracketOffset, in: bytes)
                let elemIndent = closeIndent + "  "
                let closeLineStart = lineStartOffset(of: arraySpan.closeBracketOffset, in: bytes)
                edits.append(
                    ByteEdit(
                        range: closeLineStart..<closeLineStart,
                        replacement: Array("\(elemIndent)\(encodedElem)\n".utf8)
                    )
                )
            }
        } else {
            let lastItem = arraySpan.elements[arraySpan.elements.count - 1]
            if isSameLine(arraySpan.openBracketOffset, arraySpan.closeBracketOffset, in: bytes) {
                if let comma = lastItem.trailingCommaOffset {
                    edits.append(
                        ByteEdit(
                            range: (comma + 1)..<(comma + 1),
                            replacement: Array(" \(encodedElem)".utf8)
                        )
                    )
                } else {
                    edits.append(
                        ByteEdit(
                            range: lastItem.value.end..<lastItem.value.end,
                            replacement: Array(", \(encodedElem)".utf8)
                        )
                    )
                }
            } else {
                let elemIndent = lineIndentation(of: lastItem.value.start, in: bytes)
                let closeLineStart = lineStartOffset(of: arraySpan.closeBracketOffset, in: bytes)
                if lastItem.trailingCommaOffset == nil {
                    edits.append(
                        ByteEdit(
                            range: lastItem.value.end..<lastItem.value.end,
                            replacement: Array(",".utf8)
                        )
                    )
                }
                edits.append(
                    ByteEdit(
                        range: closeLineStart..<closeLineStart,
                        replacement: Array("\(elemIndent)\(encodedElem)\n".utf8)
                    )
                )
            }
        }

        let updated = try applyEdits(edits, to: bytes)
        _ = try validateObject(updated)
        return updated
    }

    /// Removes matching string `element` occurrences from a JSON string array at `keyPath` if present.
    public static func removeStringArrayElement(
        in text: String,
        keyPath: [String],
        element: String
    ) throws -> String {
        guard !keyPath.isEmpty else {
            return text
        }

        var currentText = text
        while true {
            let bytes = Array(currentText.utf8)
            let rootObj = try parseRootObject(bytes: bytes)
            guard let node = lookupNode(in: rootObj, keyPath: keyPath) else {
                return currentText
            }
            guard case .array(let arraySpan) = node else {
                throw BentoFixesError.malformedConfiguration(
                    path: nil,
                    details: "Expected JSON array at '\(keyPath.joined(separator: "."))'"
                )
            }
            guard
                let idx = arraySpan.elements.firstIndex(where: { item in
                    if case .string(let val, _, _) = item.value {
                        return val == element
                    }
                    return false
                })
            else {
                return currentText
            }

            let target = arraySpan.elements[idx]
            var edits: [ByteEdit] = []

            if isSameLine(arraySpan.openBracketOffset, arraySpan.closeBracketOffset, in: bytes) {
                if let comma = target.trailingCommaOffset {
                    var delEnd = comma + 1
                    while delEnd < arraySpan.closeBracketOffset && isHorizontalWhitespace(bytes[delEnd]) {
                        delEnd += 1
                    }
                    edits.append(ByteEdit(range: target.value.start..<delEnd, replacement: []))
                } else if idx > 0, let prevComma = arraySpan.elements[idx - 1].trailingCommaOffset {
                    edits.append(ByteEdit(range: prevComma..<target.value.end, replacement: []))
                } else {
                    edits.append(ByteEdit(range: target.value.start..<target.value.end, replacement: []))
                }
            } else {
                let lineStart = lineStartOffset(of: target.value.start, in: bytes)
                let delStart =
                    isOnlyHorizontalWhitespace(in: lineStart..<target.value.start, bytes: bytes)
                    ? lineStart
                    : target.value.start
                let baseEnd = target.trailingCommaOffset.map { $0 + 1 } ?? target.value.end
                let delEnd = consumeTrailingTriviaOnLine(
                    from: baseEnd,
                    limit: arraySpan.closeBracketOffset,
                    bytes: bytes
                )
                edits.append(ByteEdit(range: delStart..<delEnd, replacement: []))

                if target.trailingCommaOffset == nil,
                    idx > 0,
                    idx == arraySpan.elements.count - 1,
                    let prevComma = arraySpan.elements[idx - 1].trailingCommaOffset
                {
                    edits.append(ByteEdit(range: prevComma..<(prevComma + 1), replacement: []))
                }
            }

            currentText = try applyEdits(edits, to: bytes)
            _ = try validateObject(currentText)
        }
    }

    // MARK: -JSON String Escaping

    /// Encodes a Swift `String` as a properly escaped JSON string literal (`"..."`).
    public static func encodeJSONString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22:
                out.append("\\\"")
            case 0x5C:
                out.append("\\\\")
            case 0x08:
                out.append("\\b")
            case 0x0C:
                out.append("\\f")
            case 0x0A:
                out.append("\\n")
            case 0x0D:
                out.append("\\r")
            case 0x09:
                out.append("\\t")
            case 0x00...0x1F:
                out.append(String(format: "\\u%04x", scalar.value))
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out.append("\"")
        return out
    }

    // MARK: - Internal Span Representation

    private struct ByteEdit {
        var range: Range<Int>
        var replacement: [UInt8]
    }

    private indirect enum SpanNode {
        case object(ObjectSpan)
        case array(ArraySpan)
        case string(value: String, start: Int, end: Int)
        case primitive(start: Int, end: Int)

        var start: Int {
            switch self {
            case .object(let obj):
                return obj.openBraceOffset
            case .array(let arr):
                return arr.openBracketOffset
            case .string(_, let start, _):
                return start
            case .primitive(let start, _):
                return start
            }
        }

        var end: Int {
            switch self {
            case .object(let obj):
                return obj.closeBraceOffset + 1
            case .array(let arr):
                return arr.closeBracketOffset + 1
            case .string(_, _, let end):
                return end
            case .primitive(_, let end):
                return end
            }
        }
    }

    private struct ObjectPropertySpan {
        var key: String
        var keyStart: Int
        var keyEnd: Int
        var colonOffset: Int
        var value: SpanNode
        var trailingCommaOffset: Int?
    }

    private struct ObjectSpan {
        var openBraceOffset: Int
        var closeBraceOffset: Int
        var properties: [ObjectPropertySpan]
    }

    private struct ArrayElementSpan {
        var value: SpanNode
        var trailingCommaOffset: Int?
    }

    private struct ArraySpan {
        var openBracketOffset: Int
        var closeBracketOffset: Int
        var elements: [ArrayElementSpan]
    }

    // MARK: - Edit Construction Helpers

    private static func lookupNode(in root: ObjectSpan, keyPath: [String]) -> SpanNode? {
        var current: SpanNode = .object(root)
        for segment in keyPath {
            guard case .object(let obj) = current,
                let prop = obj.properties.last(where: { $0.key == segment })
            else {
                return nil
            }
            current = prop.value
        }
        return current
    }

    private static func buildNestedObjectLiteral(
        tailKeys: [String],
        leafValueLiteral: String,
        baseIndent: String
    ) -> String {
        guard let first = tailKeys.first else {
            return leafValueLiteral
        }
        let innerIndent = baseIndent + "  "
        let innerValue = buildNestedObjectLiteral(
            tailKeys: Array(tailKeys.dropFirst()),
            leafValueLiteral: leafValueLiteral,
            baseIndent: innerIndent
        )
        return "{\n\(innerIndent)\(encodeJSONString(first)): \(innerValue)\n\(baseIndent)}"
    }

    private static func insertPropertyEdits(
        into obj: ObjectSpan,
        key: String,
        valueLiteral: String,
        bytes: [UInt8]
    ) -> [ByteEdit] {
        let encodedKey = encodeJSONString(key)

        if isSameLine(obj.openBraceOffset, obj.closeBraceOffset, in: bytes) {
            if obj.properties.isEmpty {
                let parentIndent = lineIndentation(of: obj.openBraceOffset, in: bytes)
                let childIndent = parentIndent + "  "
                let replacement = "\n\(childIndent)\(encodedKey): \(valueLiteral)\n\(parentIndent)"
                return [
                    ByteEdit(
                        range: (obj.openBraceOffset + 1)..<obj.closeBraceOffset,
                        replacement: Array(replacement.utf8)
                    )
                ]
            } else {
                let lastProp = obj.properties[obj.properties.count - 1]
                if let comma = lastProp.trailingCommaOffset {
                    return [
                        ByteEdit(
                            range: (comma + 1)..<(comma + 1),
                            replacement: Array(" \(encodedKey): \(valueLiteral)".utf8)
                        )
                    ]
                } else {
                    return [
                        ByteEdit(
                            range: lastProp.value.end..<lastProp.value.end,
                            replacement: Array(", \(encodedKey): \(valueLiteral)".utf8)
                        )
                    ]
                }
            }
        }

        let parentIndent = lineIndentation(of: obj.closeBraceOffset, in: bytes)
        let childIndent = childIndentation(for: obj, in: bytes)
        let closeLineStart = lineStartOffset(of: obj.closeBraceOffset, in: bytes)
        var edits: [ByteEdit] = []

        if let lastProp = obj.properties.last, lastProp.trailingCommaOffset == nil {
            edits.append(
                ByteEdit(
                    range: lastProp.value.end..<lastProp.value.end,
                    replacement: Array(",".utf8)
                )
            )
        }

        if isOnlyHorizontalWhitespace(in: closeLineStart..<obj.closeBraceOffset, bytes: bytes) {
            edits.append(
                ByteEdit(
                    range: closeLineStart..<closeLineStart,
                    replacement: Array("\(childIndent)\(encodedKey): \(valueLiteral)\n".utf8)
                )
            )
        } else {
            edits.append(
                ByteEdit(
                    range: obj.closeBraceOffset..<obj.closeBraceOffset,
                    replacement: Array("\n\(childIndent)\(encodedKey): \(valueLiteral)\n\(parentIndent)".utf8)
                )
            )
        }

        return edits
    }

    private static func childIndentation(for obj: ObjectSpan, in bytes: [UInt8]) -> String {
        if let lastProp = obj.properties.last {
            let propLineStart = lineStartOffset(of: lastProp.keyStart, in: bytes)
            if isOnlyHorizontalWhitespace(in: propLineStart..<lastProp.keyStart, bytes: bytes) {
                return String(decoding: bytes[propLineStart..<lastProp.keyStart], as: UTF8.self)
            }
        }
        let parentIndent = lineIndentation(of: obj.openBraceOffset, in: bytes)
        return parentIndent + "  "
    }

    private static func lineStartOffset(of offset: Int, in bytes: [UInt8]) -> Int {
        var idx = min(offset, bytes.count)
        while idx > 0 && bytes[idx - 1] != 0x0A {
            idx -= 1
        }
        return idx
    }

    private static func lineIndentation(of offset: Int, in bytes: [UInt8]) -> String {
        let start = lineStartOffset(of: offset, in: bytes)
        var end = start
        while end < bytes.count && isHorizontalWhitespace(bytes[end]) {
            end += 1
        }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private static func isSameLine(_ a: Int, _ b: Int, in bytes: [UInt8]) -> Bool {
        let lo = min(a, b)
        let hi = max(a, b)
        guard lo < hi else { return true }
        for idx in lo..<min(hi, bytes.count) where bytes[idx] == 0x0A {
            return false
        }
        return true
    }

    private static func isHorizontalWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09
    }

    private static func isOnlyHorizontalWhitespace(in range: Range<Int>, bytes: [UInt8]) -> Bool {
        for idx in range where !isHorizontalWhitespace(bytes[idx]) {
            return false
        }
        return true
    }

    private static func consumeTrailingTriviaOnLine(
        from start: Int,
        limit: Int,
        bytes: [UInt8]
    ) -> Int {
        var idx = start
        while idx < limit && isHorizontalWhitespace(bytes[idx]) {
            idx += 1
        }
        if idx + 1 < limit && bytes[idx] == UInt8(ascii: "/") && bytes[idx + 1] == UInt8(ascii: "/") {
            idx += 2
            while idx < limit && bytes[idx] != 0x0A && bytes[idx] != 0x0D {
                idx += 1
            }
        }
        if idx < limit && bytes[idx] == 0x0D {
            idx += 1
        }
        if idx < limit && bytes[idx] == 0x0A {
            idx += 1
            return idx
        }
        return start
    }

    private static func applyEdits(_ edits: [ByteEdit], to bytes: [UInt8]) throws -> String {
        var result = bytes
        let sorted = edits.sorted { lhs, rhs in
            if lhs.range.lowerBound != rhs.range.lowerBound {
                return lhs.range.lowerBound > rhs.range.lowerBound
            }
            return lhs.range.upperBound > rhs.range.upperBound
        }
        for edit in sorted {
            result.replaceSubrange(edit.range, with: edit.replacement)
        }
        guard let decoded = String(bytes: result, encoding: .utf8) else {
            throw BentoFixesError.malformedConfiguration(
                path: nil,
                details: "Edited JSONC buffer is not valid UTF-8"
            )
        }
        return decoded
    }

    private static func validateObject(_ text: String) throws -> [String: JSONValue] {
        do {
            return try JSONCParser.parseObject(text, redactSecrets: false)
        } catch {
            throw BentoFixesError.malformedConfiguration(
                path: nil,
                details: String(describing: error)
            )
        }
    }

    private static func parseRootObject(bytes: [UInt8]) throws -> ObjectSpan {
        var parser = SpanScanner(bytes: bytes)
        let root: SpanNode
        do {
            root = try parser.parseRoot()
        } catch {
            throw BentoFixesError.malformedConfiguration(
                path: nil,
                details: String(describing: error)
            )
        }
        guard case .object(let obj) = root else {
            throw BentoFixesError.malformedConfiguration(
                path: nil,
                details: "Expected top-level JSON object"
            )
        }
        return obj
    }

    // MARK: - Byte-Exact JSONC Span Scanner

    private struct SpanScanner {
        let bytes: [UInt8]
        var index: Int = 0
        var depth: Int = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
            if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
                self.index = 3
            }
        }

        mutating func parseRoot() throws -> SpanNode {
            try skipTrivia()
            let node = try parseElement()
            try skipTrivia()
            if index < bytes.count {
                throw BentoParsingError.malformedJSON(
                    message: "Unexpected trailing content after JSON root",
                    line: 1,
                    column: index + 1
                )
            }
            return node
        }

        mutating func parseElement() throws -> SpanNode {
            depth += 1
            defer { depth -= 1 }
            guard depth <= JSONCParser.defaultMaxDepth else {
                throw BentoParsingError.nestingLimitExceeded(
                    maxDepth: JSONCParser.defaultMaxDepth,
                    line: 1
                )
            }

            try skipTrivia()
            guard let byte = peek() else {
                throw BentoParsingError.malformedJSON(
                    message: "Unexpected end of JSON input",
                    line: 1,
                    column: index + 1
                )
            }

            switch byte {
            case UInt8(ascii: "{"):
                return try .object(parseObject())
            case UInt8(ascii: "["):
                return try .array(parseArray())
            case UInt8(ascii: "\""):
                let start = index
                let str = try parseString()
                return .string(value: str, start: start, end: index)
            case UInt8(ascii: "t"):
                let start = index
                try consumeKeyword("true")
                return .primitive(start: start, end: index)
            case UInt8(ascii: "f"):
                let start = index
                try consumeKeyword("false")
                return .primitive(start: start, end: index)
            case UInt8(ascii: "n"):
                let start = index
                try consumeKeyword("null")
                return .primitive(start: start, end: index)
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                let start = index
                try consumeNumber()
                return .primitive(start: start, end: index)
            default:
                throw BentoParsingError.malformedJSON(
                    message: "Unexpected token in JSON",
                    line: 1,
                    column: index + 1
                )
            }
        }

        mutating func parseObject() throws -> ObjectSpan {
            let openOffset = index
            index += 1
            try skipTrivia()
            var props: [ObjectPropertySpan] = []

            if peek() == UInt8(ascii: "}") {
                let closeOffset = index
                index += 1
                return ObjectSpan(
                    openBraceOffset: openOffset,
                    closeBraceOffset: closeOffset,
                    properties: []
                )
            }

            while true {
                try skipTrivia()
                guard peek() == UInt8(ascii: "\"") else {
                    throw BentoParsingError.malformedJSON(
                        message: "Expected quoted object key",
                        line: 1,
                        column: index + 1
                    )
                }
                let keyStart = index
                let key = try parseString()
                let keyEnd = index
                try skipTrivia()
                guard peek() == UInt8(ascii: ":") else {
                    throw BentoParsingError.malformedJSON(
                        message: "Expected ':' after object key",
                        line: 1,
                        column: index + 1
                    )
                }
                let colonOffset = index
                index += 1

                let valueNode = try parseElement()
                try skipTrivia()

                guard let next = peek() else {
                    throw BentoParsingError.malformedJSON(
                        message: "Unterminated JSON object",
                        line: 1,
                        column: index + 1
                    )
                }

                if next == UInt8(ascii: "}") {
                    props.append(
                        ObjectPropertySpan(
                            key: key,
                            keyStart: keyStart,
                            keyEnd: keyEnd,
                            colonOffset: colonOffset,
                            value: valueNode,
                            trailingCommaOffset: nil
                        )
                    )
                    let closeOffset = index
                    index += 1
                    return ObjectSpan(
                        openBraceOffset: openOffset,
                        closeBraceOffset: closeOffset,
                        properties: props
                    )
                }

                guard next == UInt8(ascii: ",") else {
                    throw BentoParsingError.malformedJSON(
                        message: "Expected ',' or '}' in JSON object",
                        line: 1,
                        column: index + 1
                    )
                }
                let commaOffset = index
                index += 1
                props.append(
                    ObjectPropertySpan(
                        key: key,
                        keyStart: keyStart,
                        keyEnd: keyEnd,
                        colonOffset: colonOffset,
                        value: valueNode,
                        trailingCommaOffset: commaOffset
                    )
                )

                try skipTrivia()
                if peek() == UInt8(ascii: "}") {
                    let closeOffset = index
                    index += 1
                    return ObjectSpan(
                        openBraceOffset: openOffset,
                        closeBraceOffset: closeOffset,
                        properties: props
                    )
                }
            }
        }

        mutating func parseArray() throws -> ArraySpan {
            let openOffset = index
            index += 1
            try skipTrivia()
            var elements: [ArrayElementSpan] = []

            if peek() == UInt8(ascii: "]") {
                let closeOffset = index
                index += 1
                return ArraySpan(
                    openBracketOffset: openOffset,
                    closeBracketOffset: closeOffset,
                    elements: []
                )
            }

            while true {
                let item = try parseElement()
                try skipTrivia()
                guard let next = peek() else {
                    throw BentoParsingError.malformedJSON(
                        message: "Unterminated JSON array",
                        line: 1,
                        column: index + 1
                    )
                }
                if next == UInt8(ascii: "]") {
                    elements.append(ArrayElementSpan(value: item, trailingCommaOffset: nil))
                    let closeOffset = index
                    index += 1
                    return ArraySpan(
                        openBracketOffset: openOffset,
                        closeBracketOffset: closeOffset,
                        elements: elements
                    )
                }
                guard next == UInt8(ascii: ",") else {
                    throw BentoParsingError.malformedJSON(
                        message: "Expected ',' or ']' in JSON array",
                        line: 1,
                        column: index + 1
                    )
                }
                let commaOffset = index
                index += 1
                elements.append(ArrayElementSpan(value: item, trailingCommaOffset: commaOffset))

                try skipTrivia()
                if peek() == UInt8(ascii: "]") {
                    let closeOffset = index
                    index += 1
                    return ArraySpan(
                        openBracketOffset: openOffset,
                        closeBracketOffset: closeOffset,
                        elements: elements
                    )
                }
            }
        }

        mutating func parseString() throws -> String {
            index += 1
            var buffer: [UInt8] = []
            while let byte = peek() {
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    guard let decoded = String(bytes: buffer, encoding: .utf8) else {
                        throw BentoParsingError.malformedJSON(
                            message: "Invalid UTF-8 in JSON string",
                            line: 1,
                            column: index
                        )
                    }
                    return decoded
                }
                if byte < 0x20 {
                    throw BentoParsingError.malformedJSON(
                        message: "Unescaped control character in JSON string",
                        line: 1,
                        column: index
                    )
                }
                if byte == UInt8(ascii: "\\") {
                    index += 1
                    guard let esc = peek() else {
                        throw BentoParsingError.malformedJSON(
                            message: "Unterminated escape in JSON string",
                            line: 1,
                            column: index
                        )
                    }
                    switch esc {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"):
                        buffer.append(esc)
                        index += 1
                    case UInt8(ascii: "b"):
                        buffer.append(0x08)
                        index += 1
                    case UInt8(ascii: "f"):
                        buffer.append(0x0C)
                        index += 1
                    case UInt8(ascii: "n"):
                        buffer.append(0x0A)
                        index += 1
                    case UInt8(ascii: "r"):
                        buffer.append(0x0D)
                        index += 1
                    case UInt8(ascii: "t"):
                        buffer.append(0x09)
                        index += 1
                    case UInt8(ascii: "u"):
                        index += 1
                        let scalar = try parseUnicodeEscape()
                        buffer.append(contentsOf: String(scalar).utf8)
                    default:
                        throw BentoParsingError.malformedJSON(
                            message: "Invalid escape in JSON string",
                            line: 1,
                            column: index
                        )
                    }
                } else {
                    buffer.append(byte)
                    index += 1
                }
            }
            throw BentoParsingError.malformedJSON(
                message: "Unterminated JSON string",
                line: 1,
                column: index
            )
        }

        mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
            let high = try readFourHex()
            if (0xD800...0xDBFF).contains(high) {
                guard peek() == UInt8(ascii: "\\"), peekNext() == UInt8(ascii: "u") else {
                    throw BentoParsingError.malformedJSON(
                        message: "Unpaired surrogate in JSON string",
                        line: 1,
                        column: index
                    )
                }
                index += 2
                let low = try readFourHex()
                guard (0xDC00...0xDFFF).contains(low) else {
                    throw BentoParsingError.malformedJSON(
                        message: "Invalid low surrogate in JSON string",
                        line: 1,
                        column: index
                    )
                }
                let cp = 0x10000 + ((UInt32(high) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                guard let scalar = Unicode.Scalar(cp) else {
                    throw BentoParsingError.malformedJSON(
                        message: "Invalid surrogate scalar",
                        line: 1,
                        column: index
                    )
                }
                return scalar
            }
            guard let scalar = Unicode.Scalar(UInt32(high)) else {
                throw BentoParsingError.malformedJSON(
                    message: "Invalid unicode scalar",
                    line: 1,
                    column: index
                )
            }
            return scalar
        }

        mutating func readFourHex() throws -> UInt16 {
            var val: UInt16 = 0
            for _ in 0..<4 {
                guard let byte = peek(), let nib = hexNibble(byte) else {
                    throw BentoParsingError.malformedJSON(
                        message: "Invalid \\u hex escape",
                        line: 1,
                        column: index
                    )
                }
                val = (val << 4) | UInt16(nib)
                index += 1
            }
            return val
        }

        mutating func consumeKeyword(_ keyword: String) throws {
            for expected in keyword.utf8 {
                guard peek() == expected else {
                    throw BentoParsingError.malformedJSON(
                        message: "Expected '\(keyword)'",
                        line: 1,
                        column: index
                    )
                }
                index += 1
            }
        }

        mutating func consumeNumber() throws {
            if peek() == UInt8(ascii: "-") {
                index += 1
            }
            guard let first = peek(), first >= UInt8(ascii: "0"), first <= UInt8(ascii: "9") else {
                throw BentoParsingError.malformedJSON(
                    message: "Invalid number",
                    line: 1,
                    column: index
                )
            }
            while let d = peek(), d >= UInt8(ascii: "0"), d <= UInt8(ascii: "9") {
                index += 1
            }
            if peek() == UInt8(ascii: ".") {
                index += 1
                while let d = peek(), d >= UInt8(ascii: "0"), d <= UInt8(ascii: "9") {
                    index += 1
                }
            }
            if let exp = peek(), exp == UInt8(ascii: "e") || exp == UInt8(ascii: "E") {
                index += 1
                if let sign = peek(), sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
                    index += 1
                }
                while let d = peek(), d >= UInt8(ascii: "0"), d <= UInt8(ascii: "9") {
                    index += 1
                }
            }
        }

        mutating func skipTrivia() throws {
            while let byte = peek() {
                switch byte {
                case 0x20, 0x09, 0x0A, 0x0D:
                    index += 1
                case UInt8(ascii: "/"):
                    if peekNext() == UInt8(ascii: "/") {
                        index += 2
                        while let c = peek(), c != 0x0A {
                            index += 1
                        }
                    } else if peekNext() == UInt8(ascii: "*") {
                        index += 2
                        var closed = false
                        while let c = peek() {
                            if c == UInt8(ascii: "*") && peekNext() == UInt8(ascii: "/") {
                                index += 2
                                closed = true
                                break
                            }
                            index += 1
                        }
                        if !closed {
                            throw BentoParsingError.malformedJSON(
                                message: "Unterminated block comment",
                                line: 1,
                                column: index
                            )
                        }
                    } else {
                        return
                    }
                default:
                    return
                }
            }
        }

        func peek() -> UInt8? {
            index < bytes.count ? bytes[index] : nil
        }

        func peekNext() -> UInt8? {
            (index + 1) < bytes.count ? bytes[index + 1] : nil
        }

        func hexNibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                return byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"):
                return byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"):
                return byte - UInt8(ascii: "A") + 10
            default:
                return nil
            }
        }
    }
}
