import Foundation
import Testing

@testable import BentoCore

struct DependencyGraphTests {
    static let allowedDependencies: [String: Set<String>] = [
        "BentoCore": [],
        "BentoParsing": ["BentoCore"],
        "BentoAdapters": ["BentoCore", "BentoParsing"],
        "BentoScanner": ["BentoCore", "BentoParsing", "BentoAdapters"],
        "BentoTokenizer": ["BentoCore"],
        "BentoLogIngest": ["BentoCore", "BentoParsing", "CZstd"],
        "BentoMCPProbe": ["BentoCore"],
        "BentoHygiene": ["BentoCore", "BentoParsing", "BentoTokenizer"],
        "BentoStore": ["BentoCore"],
        "BentoFixes": ["BentoCore", "BentoParsing", "BentoStore"],
        "BentoUI": [
            "BentoCore",
            "BentoScanner",
            "BentoLogIngest",
            "BentoTokenizer",
            "BentoMCPProbe",
            "BentoHygiene",
            "BentoFixes",
            "BentoStore"
        ],
        "bentoctx": [
            "BentoCore",
            "BentoScanner",
            "BentoLogIngest",
            "BentoTokenizer",
            "BentoMCPProbe",
            "BentoHygiene",
            "BentoFixes",
            "BentoStore"
        ],
        "BentoApp": ["BentoUI"],
        "CZstd": []
    ]

    static let requiredTargets: Set<String> = [
        "BentoCore",
        "BentoParsing",
        "BentoAdapters",
        "BentoScanner",
        "BentoTokenizer",
        "BentoLogIngest",
        "BentoMCPProbe",
        "BentoHygiene",
        "BentoStore",
        "BentoFixes",
        "BentoUI",
        "bentoctx",
        "BentoApp"
    ]

    @Test("Package.swift targets and dependencies obey PLAN §3.1 and §3.2")
    func packageManifestMatchesArchitectureGraph() throws {
        let repoRoot = Self.repositoryRoot()
        let manifestURL = repoRoot.appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        let parsed = PackageManifestParser.parseNonTestTargets(from: manifest)

        let actualTargetNames = Set(parsed.keys)
        for required in Self.requiredTargets {
            #expect(actualTargetNames.contains(required), "Missing required target: \(required)")
        }

        let violations = Self.findViolations(in: parsed)
        #expect(violations.isEmpty, "Dependency graph violations: \(violations.joined(separator: "; "))")

        #expect(
            parsed["bentoctx"] == parsed["BentoUI"],
            "CLI internal dependencies must match UI internal dependencies (PLAN §3.2)"
        )
        #expect(parsed["BentoCore"] == [], "BentoCore must have zero target dependencies")
    }

    @Test("Parser detects forbidden dependency edges on synthetic manifests")
    func parserCatchesForbiddenEdges() {
        let invalidManifest = """
            let package = Package(
                name: "Sample",
                targets: [
                    .target(
                        name: "BentoCore",
                        dependencies: ["BentoStore"]
                    ),
                    .target(
                        name: "BentoUI",
                        dependencies: ["BentoAdapters"]
                    )
                ]
            )
            """
        let parsed = PackageManifestParser.parseNonTestTargets(from: invalidManifest)
        let violations = Self.findViolations(in: parsed)
        #expect(violations.count == 2)
    }

    @Test("BentoCore never imports SwiftUI, AppKit, GRDB, or higher modules")
    func coreHasNoForbiddenImports() throws {
        let coreDir = Self.repositoryRoot().appendingPathComponent("Sources/BentoCore")
        let enumerator = FileManager.default.enumerator(
            at: coreDir,
            includingPropertiesForKeys: nil
        )
        let forbiddenImports: Set<String> = [
            "SwiftUI",
            "AppKit",
            "Combine",
            "GRDB",
            "BentoParsing",
            "BentoAdapters",
            "BentoScanner",
            "BentoLogIngest",
            "BentoTokenizer",
            "BentoMCPProbe",
            "BentoHygiene",
            "BentoFixes",
            "BentoStore",
            "BentoUI"
        ]

        var swiftFileCount = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            swiftFileCount += 1
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            for line in contents.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let imported = trimmed.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
                #expect(
                    !forbiddenImports.contains(imported),
                    "Forbidden import '\(imported)' in \(fileURL.lastPathComponent)"
                )
            }
        }
        #expect(swiftFileCount > 0)
    }

    @Test("Every Source module directory contains a README.md (PLAN §10)")
    func everyModuleHasReadme() throws {
        let sourcesDir = Self.repositoryRoot().appendingPathComponent("Sources")
        let entries = try FileManager.default.contentsOfDirectory(
            at: sourcesDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        #expect(!entries.isEmpty)
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            let readmeURL = entry.appendingPathComponent("README.md")
            #expect(
                FileManager.default.fileExists(atPath: readmeURL.path),
                "Missing README.md in Sources/\(entry.lastPathComponent)"
            )
        }
    }

    private static func findViolations(in graph: [String: Set<String>]) -> [String] {
        var violations: [String] = []
        for (target, dependencies) in graph.sorted(by: { $0.key < $1.key }) {
            guard let allowed = allowedDependencies[target] else {
                violations.append("Unexpected target '\(target)' not listed in PLAN §3.2")
                continue
            }
            let forbidden = dependencies.subtracting(allowed)
            if !forbidden.isEmpty {
                let list = forbidden.sorted().joined(separator: ", ")
                violations.append("\(target) depends on forbidden target(s): \(list)")
            }
        }
        return violations
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

enum PackageManifestParser {
    static func parseNonTestTargets(from manifest: String) -> [String: Set<String>] {
        let stripped = stripComments(from: manifest)
        let targetPrefixes = [".target(", ".executableTarget(", ".systemLibrary("]
        var result: [String: Set<String>] = [:]
        var searchIndex = stripped.startIndex

        while searchIndex < stripped.endIndex {
            var earliestMatch: (range: Range<String.Index>, prefix: String)?
            for prefix in targetPrefixes {
                if let range = stripped.range(of: prefix, range: searchIndex..<stripped.endIndex) {
                    if let current = earliestMatch {
                        if range.lowerBound < current.range.lowerBound {
                            earliestMatch = (range, prefix)
                        }
                    } else {
                        earliestMatch = (range, prefix)
                    }
                }
            }

            guard let match = earliestMatch else { break }
            let openParenIndex = stripped.index(before: match.range.upperBound)
            guard
                let closeParenIndex = matchingClosingDelimiter(
                    in: stripped,
                    from: openParenIndex,
                    open: "(",
                    close: ")"
                )
            else {
                break
            }

            let bodyStart = stripped.index(after: openParenIndex)
            let body = String(stripped[bodyStart..<closeParenIndex])
            if let name = extractTargetName(from: body), !isTestSupportTarget(body: body) {
                let deps = extractInternalDependencies(from: body)
                result[name] = deps
            }
            searchIndex = stripped.index(after: closeParenIndex)
        }

        return result
    }

    private static func isTestSupportTarget(body: String) -> Bool {
        guard let pathRange = body.range(of: "path:") else { return false }
        let afterPath = String(body[pathRange.upperBound...])
        guard let targetPath = firstQuotedString(in: afterPath) else { return false }
        return targetPath.hasPrefix("Tests/")
    }

    private static func extractTargetName(from targetBody: String) -> String? {
        guard let nameRange = targetBody.range(of: "name:") else { return nil }
        let afterName = targetBody[nameRange.upperBound...]
        return firstQuotedString(in: String(afterName))
    }

    private static func extractInternalDependencies(from targetBody: String) -> Set<String> {
        guard let depRange = targetBody.range(of: "dependencies:") else { return [] }
        let remainder = targetBody[depRange.upperBound...]
        guard let openBracket = remainder.firstIndex(of: "[") else { return [] }
        guard
            let closeBracket = matchingClosingDelimiter(
                in: targetBody,
                from: openBracket,
                open: "[",
                close: "]"
            )
        else {
            return []
        }

        let arrayBody = String(targetBody[targetBody.index(after: openBracket)..<closeBracket])
        let withoutProducts = removeBalancedCalls(named: ".product(", from: arrayBody)
        return Set(allQuotedStrings(in: withoutProducts))
    }

    private static func removeBalancedCalls(named prefix: String, from text: String) -> String {
        var output = text
        while let range = output.range(of: prefix) {
            let openParen = output.index(before: range.upperBound)
            guard
                let closeParen = matchingClosingDelimiter(
                    in: output,
                    from: openParen,
                    open: "(",
                    close: ")"
                )
            else {
                break
            }
            output.removeSubrange(range.lowerBound...closeParen)
        }
        return output
    }

    private static func matchingClosingDelimiter(
        in text: String,
        from openIndex: String.Index,
        open: Character,
        close: Character
    ) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = openIndex

        while index < text.endIndex {
            let char = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                } else if char == open {
                    depth += 1
                } else if char == close {
                    depth -= 1
                    if depth == 0 {
                        return index
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func firstQuotedString(in text: String) -> String? {
        allQuotedStrings(in: text).first
    }

    private static func allQuotedStrings(in text: String) -> [String] {
        var results: [String] = []
        var inString = false
        var escaped = false
        var current = ""

        for char in text {
            if inString {
                if escaped {
                    current.append(char)
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    results.append(current)
                    current = ""
                    inString = false
                } else {
                    current.append(char)
                }
            } else if char == "\"" {
                inString = true
            }
        }
        return results
    }

    private static func stripComments(from source: String) -> String {
        var output = ""
        var inString = false
        var escaped = false
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)

        for line in lines {
            var lineOut = ""
            var prev: Character?
            for char in line {
                if inString {
                    lineOut.append(char)
                    if escaped {
                        escaped = false
                    } else if char == "\\" {
                        escaped = true
                    } else if char == "\"" {
                        inString = false
                    }
                    prev = char
                } else {
                    if char == "\"" {
                        inString = true
                        lineOut.append(char)
                        prev = char
                    } else if char == "/" && prev == "/" {
                        lineOut.removeLast()
                        break
                    } else {
                        lineOut.append(char)
                        prev = char
                    }
                }
            }
            output.append(lineOut)
            output.append("\n")
        }
        return output
    }
}
