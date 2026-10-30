import BentoCore
import Foundation
import TOMLDecoder

/// Read-only TOML parser backed by `TOMLDecoder` (`Docs/decisions/001-toml-library.md`) with parse-time redaction.
public enum TOMLParser {
    /// Default recursion depth limit protecting against adversarial deeply nested tables/arrays.
    public static let defaultMaxDepth = 128

    /// Parses a TOML string into a `[String: JSONValue]` dictionary.
    public static func parseObject(
        _ text: String,
        redactSecrets: Bool = true,
        maxDepth: Int = defaultMaxDepth
    ) throws -> [String: JSONValue] {
        let cleaned = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let rawDictionary: [String: Any]
        do {
            let table = try TOMLTable(source: cleaned)
            rawDictionary = try Dictionary(table)
        } catch {
            throw BentoParsingError.malformedTOML(message: String(describing: error))
        }

        let converted = try convertDictionary(rawDictionary, depth: 1, maxDepth: maxDepth)
        return redactSecrets ? SecretRedactor.redact(converted) : converted
    }

    /// Parses UTF-8 TOML bytes into a `[String: JSONValue]` dictionary.
    public static func parseObject(
        _ data: Data,
        redactSecrets: Bool = true,
        maxDepth: Int = defaultMaxDepth
    ) throws -> [String: JSONValue] {
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw BentoParsingError.invalidUTF8
        }
        return try parseObject(text, redactSecrets: redactSecrets, maxDepth: maxDepth)
    }

    /// Tolerantly parses a TOML settings file, converting errors into `Diagnostic` entries.
    public static func parseSettings(
        _ data: Data,
        location: SourceLocation? = nil,
        redactSecrets: Bool = true,
        maxDepth: Int = defaultMaxDepth
    ) -> (settings: SettingsDoc?, diagnostics: [Diagnostic]) {
        do {
            let tree = try parseObject(data, redactSecrets: redactSecrets, maxDepth: maxDepth)
            return (SettingsDoc(format: .toml, tree: tree), [])
        } catch let error as BentoParsingError {
            let code: String
            let message: String
            switch error {
            case .invalidUTF8:
                code = "toml.invalidUTF8"
                message = "TOML file is not valid UTF-8"
            case .malformedTOML(let details):
                code = "toml.malformed"
                message = details
            case .nestingLimitExceeded(let limit, _):
                code = "toml.nestingLimitExceeded"
                message = "TOML nesting exceeded maximum depth of \(limit)"
            case .malformedJSON, .expectedJSONObject, .malformedFrontmatter, .expectedFrontmatterMapping:
                code = "toml.malformed"
                message = String(describing: error)
            }
            return (
                nil,
                [
                    Diagnostic(
                        code: code,
                        severity: .error,
                        message: message,
                        location: location
                    )
                ]
            )
        } catch {
            return (
                nil,
                [
                    Diagnostic(
                        code: "toml.malformed",
                        severity: .error,
                        message: String(describing: error),
                        location: location
                    )
                ]
            )
        }
    }

    private static func convertDictionary(
        _ dictionary: [String: Any],
        depth: Int,
        maxDepth: Int
    ) throws -> [String: JSONValue] {
        guard depth <= maxDepth else {
            throw BentoParsingError.nestingLimitExceeded(maxDepth: maxDepth, line: 1)
        }
        var output: [String: JSONValue] = [:]
        output.reserveCapacity(dictionary.count)
        for (key, value) in dictionary {
            output[key] = try convertValue(value, depth: depth + 1, maxDepth: maxDepth)
        }
        return output
    }

    private static func convertValue(
        _ value: Any,
        depth: Int,
        maxDepth: Int
    ) throws -> JSONValue {
        guard depth <= maxDepth else {
            throw BentoParsingError.nestingLimitExceeded(maxDepth: maxDepth, line: 1)
        }

        if let boolVal = value as? Bool {
            return .bool(boolVal)
        }
        if let int64Val = value as? Int64 {
            return .int(int64Val)
        }
        if let intVal = value as? Int {
            return .int(Int64(intVal))
        }
        if let doubleVal = value as? Double {
            if doubleVal.isFinite {
                return .double(doubleVal)
            }
            return .string(String(doubleVal))
        }
        if let stringVal = value as? String {
            return .string(stringVal)
        }
        if let arrayVal = value as? [Any] {
            return try .array(arrayVal.map { try convertValue($0, depth: depth + 1, maxDepth: maxDepth) })
        }
        if let tableVal = value as? [String: Any] {
            return try .object(convertDictionary(tableVal, depth: depth, maxDepth: maxDepth))
        }

        // TOML date/time scalars (`OffsetDateTime`, `LocalDateTime`, `LocalDate`, `LocalTime`)
        return .string(String(describing: value))
    }
}
