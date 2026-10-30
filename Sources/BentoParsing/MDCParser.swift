import BentoCore
import Foundation

/// Parser for Cursor `.cursor/rules/**/*.mdc` rule files.
public enum MDCParser {
    /// Parses a `.mdc` rule string into an `MDCDocument`.
    public static func parse(
        _ text: String,
        location: SourceLocation? = nil,
        redactSecrets: Bool = true
    ) -> MDCDocument {
        let parsed = FrontmatterParser.parse(text, location: location, redactSecrets: redactSecrets)
        let frontmatter = parsed.frontmatter

        let description: String?
        if case .string(let desc) = frontmatter?["description"] {
            let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
            description = trimmed.isEmpty ? nil : trimmed
        } else {
            description = nil
        }

        let globs = extractGlobs(from: frontmatter?["globs"])
        let alwaysApply = extractBool(from: frontmatter?["alwaysApply"]) ?? false

        let effectiveLoadMode: LoadMode
        if alwaysApply {
            effectiveLoadMode = .always
        } else if !globs.isEmpty {
            effectiveLoadMode = .conditional(globs: globs)
        } else {
            effectiveLoadMode = .onInvoke
        }

        let imports = ImportResolver.extractImports(
            from: parsed.body,
            startingAtLine: parsed.bodyStartLine
        ).map(\.path)

        let rulesDoc = RulesDoc(
            content: parsed.body,
            imports: imports,
            frontmatter: frontmatter,
            byteCount: text.utf8.count,
            characterCount: text.count,
            wasTruncated: false
        )

        return MDCDocument(
            description: description,
            globs: globs,
            alwaysApply: alwaysApply,
            effectiveLoadMode: effectiveLoadMode,
            rulesDoc: rulesDoc,
            bodyStartLine: parsed.bodyStartLine,
            diagnostics: parsed.diagnostics
        )
    }

    /// Parses UTF-8 `.mdc` bytes into an `MDCDocument`.
    public static func parse(
        _ data: Data,
        location: SourceLocation? = nil,
        redactSecrets: Bool = true
    ) throws -> MDCDocument {
        guard let text = String(data: data, encoding: .utf8) else {
            throw BentoParsingError.invalidUTF8
        }
        return parse(text, location: location, redactSecrets: redactSecrets)
    }

    private static func extractGlobs(from value: JSONValue?) -> [String] {
        guard let value else { return [] }
        switch value {
        case .array(let elements):
            return elements.compactMap { element -> String? in
                guard case .string(let raw) = element else { return nil }
                return cleanGlobToken(raw)
            }
        case .string(let csv):
            return
                csv
                .split(separator: ",")
                .compactMap { cleanGlobToken(String($0)) }
        default:
            return []
        }
    }

    private static func cleanGlobToken(_ token: String) -> String? {
        var trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
            || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'"))
        {
            if trimmed.count >= 2 {
                trimmed.removeFirst()
                trimmed.removeLast()
            }
        }
        let cleaned = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func extractBool(from value: JSONValue?) -> Bool? {
        guard let value else { return nil }
        switch value {
        case .bool(let flag):
            return flag
        case .string(let str):
            switch str.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes":
                return true
            case "false", "no":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
