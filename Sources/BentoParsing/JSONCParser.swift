import BentoCore
import Foundation

/// Tolerant JSON and JSONC (`//`, `/* */`, trailing commas) parser with parse-time secret redaction.
public enum JSONCParser {
    /// Default recursion depth limit protecting against adversarial deeply nested inputs.
    public static let defaultMaxDepth = 128

    /// Parses a JSON/JSONC string into a `JSONValue`.
    public static func parseValue(
        _ text: String,
        redactSecrets: Bool = true,
        maxDepth: Int = defaultMaxDepth
    ) throws -> JSONValue {
        let cleaned = stripBOM(from: text)
        var scanner = Scanner(bytes: Array(cleaned.utf8), maxDepth: maxDepth)
        let rawValue = try scanner.parseRoot()
        return redactSecrets ? SecretRedactor.redact(rawValue) : rawValue
    }

    /// Parses UTF-8 JSON/JSONC bytes into a `JSONValue`.
    public static func parseValue(
        _ data: Data,
        redactSecrets: Bool = true,
        maxDepth: Int = defaultMaxDepth
    ) throws -> JSONValue {
        guard let text = decodeValidatedUTF8(data) else {
            throw BentoParsingError.invalidUTF8
        }
        return try parseValue(text, redactSecrets: redactSecrets, maxDepth: maxDepth)
    }

    /// Parses a top-level JSON/JSONC object from a string.
    public static func parseObject(
        _ text: String,
        redactSecrets: Bool = true,
        maxDepth: Int = defaultMaxDepth
    ) throws -> [String: JSONValue] {
        let value = try parseValue(text, redactSecrets: redactSecrets, maxDepth: maxDepth)
        guard case .object(let dictionary) = value else {
            throw BentoParsingError.expectedJSONObject
        }
        return dictionary
    }

    /// Parses a top-level JSON/JSONC object from UTF-8 bytes.
    public static func parseObject(
        _ data: Data,
        redactSecrets: Bool = true,
        maxDepth: Int = defaultMaxDepth
    ) throws -> [String: JSONValue] {
        let value = try parseValue(data, redactSecrets: redactSecrets, maxDepth: maxDepth)
        guard case .object(let dictionary) = value else {
            throw BentoParsingError.expectedJSONObject
        }
        return dictionary
    }

    /// Tolerantly parses a JSON/JSONC settings file, converting errors into `Diagnostic` entries.
    public static func parseSettings(
        _ data: Data,
        location: SourceLocation? = nil,
        redactSecrets: Bool = true,
        maxDepth: Int = defaultMaxDepth
    ) -> (settings: SettingsDoc?, diagnostics: [Diagnostic]) {
        do {
            let tree = try parseObject(data, redactSecrets: redactSecrets, maxDepth: maxDepth)
            return (SettingsDoc(format: .json, tree: tree), [])
        } catch let error as BentoParsingError {
            return (nil, [diagnostic(from: error, baseLocation: location)])
        } catch {
            let diag = Diagnostic(
                code: "json.malformed",
                severity: .error,
                message: String(describing: error),
                location: location
            )
            return (nil, [diag])
        }
    }

    private static func diagnostic(from error: BentoParsingError, baseLocation: SourceLocation?) -> Diagnostic {
        switch error {
        case .invalidUTF8:
            return Diagnostic(
                code: "json.invalidUTF8",
                severity: .error,
                message: "JSON file is not valid UTF-8",
                location: baseLocation
            )
        case .malformedJSON(let message, let line, let column):
            var loc = baseLocation
            if var existing = loc {
                existing.lineRange = line...line
                loc = existing
            }
            return Diagnostic(
                code: "json.malformed",
                severity: .error,
                message: "\(message) (line \(line), column \(column))",
                location: loc
            )
        case .expectedJSONObject:
            return Diagnostic(
                code: "json.expectedObject",
                severity: .error,
                message: "Expected top-level JSON object",
                location: baseLocation
            )
        case .nestingLimitExceeded(let limit, let line):
            var loc = baseLocation
            if var existing = loc {
                existing.lineRange = line...line
                loc = existing
            }
            return Diagnostic(
                code: "json.nestingLimitExceeded",
                severity: .error,
                message: "JSON nesting exceeded maximum depth of \(limit)",
                location: loc
            )
        case .malformedTOML, .malformedFrontmatter, .expectedFrontmatterMapping:
            return Diagnostic(
                code: "json.malformed",
                severity: .error,
                message: String(describing: error),
                location: baseLocation
            )
        }
    }

    private static func stripBOM(from text: String) -> String {
        if text.hasPrefix("\u{FEFF}") {
            return String(text.dropFirst())
        }
        return text
    }

    private static func decodeValidatedUTF8(_ data: Data) -> String? {
        String(bytes: data, encoding: .utf8)
    }

    private struct Scanner {
        let bytes: [UInt8]
        let maxDepth: Int
        var index: Int = 0
        var line: Int = 1
        var column: Int = 1

        mutating func parseRoot() throws -> JSONValue {
            try skipTrivia()
            let root = try parseElement(depth: 1)
            try skipTrivia()
            if index < bytes.count {
                throw BentoParsingError.malformedJSON(
                    message: "Unexpected trailing content after JSON root value",
                    line: line,
                    column: column
                )
            }
            return root
        }

        mutating func parseElement(depth: Int) throws -> JSONValue {
            guard depth <= maxDepth else {
                throw BentoParsingError.nestingLimitExceeded(maxDepth: maxDepth, line: line)
            }
            try skipTrivia()
            guard let byte = peek() else {
                throw BentoParsingError.malformedJSON(
                    message: "Unexpected end of input",
                    line: line,
                    column: column
                )
            }

            switch byte {
            case UInt8(ascii: "{"):
                return try .object(parseObjectLiteral(depth: depth))
            case UInt8(ascii: "["):
                return try .array(parseArrayLiteral(depth: depth))
            case UInt8(ascii: "\""):
                return try .string(parseStringLiteral())
            case UInt8(ascii: "t"):
                try consumeKeyword("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try consumeKeyword("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try consumeKeyword("null")
                return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                return try parseNumberLiteral()
            default:
                throw BentoParsingError.malformedJSON(
                    message: "Unexpected character",
                    line: line,
                    column: column
                )
            }
        }

        mutating func parseObjectLiteral(depth: Int) throws -> [String: JSONValue] {
            advance()
            try skipTrivia()
            var object: [String: JSONValue] = [:]

            if peek() == UInt8(ascii: "}") {
                advance()
                return object
            }

            while true {
                try skipTrivia()
                guard peek() == UInt8(ascii: "\"") else {
                    throw BentoParsingError.malformedJSON(
                        message: "Expected quoted property name in JSON object",
                        line: line,
                        column: column
                    )
                }
                let key = try parseStringLiteral()
                try skipTrivia()
                guard peek() == UInt8(ascii: ":") else {
                    throw BentoParsingError.malformedJSON(
                        message: "Expected ':' after object property name",
                        line: line,
                        column: column
                    )
                }
                advance()

                let value = try parseElement(depth: depth + 1)
                object[key] = value

                try skipTrivia()
                guard let next = peek() else {
                    throw BentoParsingError.malformedJSON(
                        message: "Unterminated JSON object",
                        line: line,
                        column: column
                    )
                }
                if next == UInt8(ascii: "}") {
                    advance()
                    return object
                }
                guard next == UInt8(ascii: ",") else {
                    throw BentoParsingError.malformedJSON(
                        message: "Expected ',' or '}' in JSON object",
                        line: line,
                        column: column
                    )
                }
                advance()
                try skipTrivia()
                // Trailing comma tolerance before '}'
                if peek() == UInt8(ascii: "}") {
                    advance()
                    return object
                }
            }
        }

        mutating func parseArrayLiteral(depth: Int) throws -> [JSONValue] {
            advance()
            try skipTrivia()
            var array: [JSONValue] = []

            if peek() == UInt8(ascii: "]") {
                advance()
                return array
            }

            while true {
                let item = try parseElement(depth: depth + 1)
                array.append(item)

                try skipTrivia()
                guard let next = peek() else {
                    throw BentoParsingError.malformedJSON(
                        message: "Unterminated JSON array",
                        line: line,
                        column: column
                    )
                }
                if next == UInt8(ascii: "]") {
                    advance()
                    return array
                }
                guard next == UInt8(ascii: ",") else {
                    throw BentoParsingError.malformedJSON(
                        message: "Expected ',' or ']' in JSON array",
                        line: line,
                        column: column
                    )
                }
                advance()
                try skipTrivia()
                // Trailing comma tolerance before ']'
                if peek() == UInt8(ascii: "]") {
                    advance()
                    return array
                }
            }
        }

        mutating func parseStringLiteral() throws -> String {
            let startLine = line
            let startCol = column
            advance()
            var utf8Buffer: [UInt8] = []

            while let byte = peek() {
                if byte == UInt8(ascii: "\"") {
                    advance()
                    guard let decoded = String(bytes: utf8Buffer, encoding: .utf8) else {
                        throw BentoParsingError.malformedJSON(
                            message: "Invalid UTF-8 sequence in JSON string",
                            line: startLine,
                            column: startCol
                        )
                    }
                    return decoded
                }

                if byte < 0x20 {
                    throw BentoParsingError.malformedJSON(
                        message: "Unescaped control character in JSON string",
                        line: line,
                        column: column
                    )
                }

                if byte == UInt8(ascii: "\\") {
                    advance()
                    guard let esc = peek() else {
                        throw BentoParsingError.malformedJSON(
                            message: "Unterminated escape sequence in JSON string",
                            line: line,
                            column: column
                        )
                    }
                    switch esc {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"):
                        utf8Buffer.append(esc)
                        advance()
                    case UInt8(ascii: "b"):
                        utf8Buffer.append(0x08)
                        advance()
                    case UInt8(ascii: "f"):
                        utf8Buffer.append(0x0C)
                        advance()
                    case UInt8(ascii: "n"):
                        utf8Buffer.append(0x0A)
                        advance()
                    case UInt8(ascii: "r"):
                        utf8Buffer.append(0x0D)
                        advance()
                    case UInt8(ascii: "t"):
                        utf8Buffer.append(0x09)
                        advance()
                    case UInt8(ascii: "u"):
                        advance()
                        let scalar = try parseUnicodeEscape()
                        utf8Buffer.append(contentsOf: String(scalar).utf8)
                    default:
                        throw BentoParsingError.malformedJSON(
                            message: "Invalid escape character in JSON string",
                            line: line,
                            column: column
                        )
                    }
                } else {
                    utf8Buffer.append(byte)
                    advance()
                }
            }

            throw BentoParsingError.malformedJSON(
                message: "Unterminated JSON string literal",
                line: startLine,
                column: startCol
            )
        }

        mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
            let high = try readFourHexDigits()
            if (0xD800...0xDBFF).contains(high) {
                guard peek() == UInt8(ascii: "\\"), peekNext() == UInt8(ascii: "u") else {
                    throw BentoParsingError.malformedJSON(
                        message: "Unpaired UTF-16 high surrogate in JSON string",
                        line: line,
                        column: column
                    )
                }
                advance()
                advance()
                let low = try readFourHexDigits()
                guard (0xDC00...0xDFFF).contains(low) else {
                    throw BentoParsingError.malformedJSON(
                        message: "Invalid UTF-16 low surrogate in JSON string",
                        line: line,
                        column: column
                    )
                }
                let codePoint = 0x10000 + ((UInt32(high) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                guard let scalar = Unicode.Scalar(codePoint) else {
                    throw BentoParsingError.malformedJSON(
                        message: "Invalid surrogate pair code point",
                        line: line,
                        column: column
                    )
                }
                return scalar
            }

            guard let scalar = Unicode.Scalar(UInt32(high)) else {
                throw BentoParsingError.malformedJSON(
                    message: "Invalid Unicode scalar escape",
                    line: line,
                    column: column
                )
            }
            return scalar
        }

        mutating func readFourHexDigits() throws -> UInt16 {
            var value: UInt16 = 0
            for _ in 0..<4 {
                guard let byte = peek(), let nibble = hexValue(byte) else {
                    throw BentoParsingError.malformedJSON(
                        message: "Expected 4 hexadecimal digits in \\u escape",
                        line: line,
                        column: column
                    )
                }
                value = (value << 4) | UInt16(nibble)
                advance()
            }
            return value
        }

        mutating func parseNumberLiteral() throws -> JSONValue {
            let startIndex = index
            let startLine = line
            let startCol = column
            var isFloatingPoint = false

            if peek() == UInt8(ascii: "-") {
                advance()
            }

            guard let firstDigit = peek(), isDigit(firstDigit) else {
                throw BentoParsingError.malformedJSON(
                    message: "Invalid JSON number literal",
                    line: startLine,
                    column: startCol
                )
            }

            if firstDigit == UInt8(ascii: "0") {
                advance()
                if let afterZero = peek(), isDigit(afterZero) {
                    throw BentoParsingError.malformedJSON(
                        message: "Leading zeros are not permitted in JSON numbers",
                        line: line,
                        column: column
                    )
                }
            } else {
                while let d = peek(), isDigit(d) {
                    advance()
                }
            }

            if peek() == UInt8(ascii: ".") {
                isFloatingPoint = true
                advance()
                guard let fracDigit = peek(), isDigit(fracDigit) else {
                    throw BentoParsingError.malformedJSON(
                        message: "Expected digit after decimal point in JSON number",
                        line: line,
                        column: column
                    )
                }
                while let d = peek(), isDigit(d) {
                    advance()
                }
            }

            if let expByte = peek(), expByte == UInt8(ascii: "e") || expByte == UInt8(ascii: "E") {
                isFloatingPoint = true
                advance()
                if let sign = peek(), sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
                    advance()
                }
                guard let expDigit = peek(), isDigit(expDigit) else {
                    throw BentoParsingError.malformedJSON(
                        message: "Expected exponent digit in JSON number",
                        line: line,
                        column: column
                    )
                }
                while let d = peek(), isDigit(d) {
                    advance()
                }
            }

            let numberText = String(decoding: bytes[startIndex..<index], as: UTF8.self)
            if !isFloatingPoint {
                if let intVal = Int64(numberText) {
                    return .int(intVal)
                }
            }
            guard let doubleVal = Double(numberText), doubleVal.isFinite else {
                throw BentoParsingError.malformedJSON(
                    message: "JSON number out of representable range",
                    line: startLine,
                    column: startCol
                )
            }
            return .double(doubleVal)
        }

        mutating func consumeKeyword(_ keyword: String) throws {
            let startLine = line
            let startCol = column
            for expected in keyword.utf8 {
                guard peek() == expected else {
                    throw BentoParsingError.malformedJSON(
                        message: "Invalid literal; expected '\(keyword)'",
                        line: startLine,
                        column: startCol
                    )
                }
                advance()
            }
        }

        mutating func skipTrivia() throws {
            while let byte = peek() {
                switch byte {
                case 0x20, 0x09, 0x0D, 0x0A:
                    advance()
                case UInt8(ascii: "/"):
                    let next = peekNext()
                    if next == UInt8(ascii: "/") {
                        advance()
                        advance()
                        while let c = peek(), c != 0x0A {
                            advance()
                        }
                    } else if next == UInt8(ascii: "*") {
                        let commentLine = line
                        let commentCol = column
                        advance()
                        advance()
                        var closed = false
                        while let c = peek() {
                            if c == UInt8(ascii: "*") && peekNext() == UInt8(ascii: "/") {
                                advance()
                                advance()
                                closed = true
                                break
                            }
                            advance()
                        }
                        if !closed {
                            throw BentoParsingError.malformedJSON(
                                message: "Unterminated block comment",
                                line: commentLine,
                                column: commentCol
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
            guard index < bytes.count else { return nil }
            return bytes[index]
        }

        func peekNext() -> UInt8? {
            let nextIdx = index + 1
            guard nextIdx < bytes.count else { return nil }
            return bytes[nextIdx]
        }

        mutating func advance() {
            guard index < bytes.count else { return }
            if bytes[index] == 0x0A {
                line += 1
                column = 1
            } else {
                column += 1
            }
            index += 1
        }

        func isDigit(_ byte: UInt8) -> Bool {
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }

        func hexValue(_ byte: UInt8) -> UInt8? {
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
