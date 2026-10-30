import BentoCore
import Foundation

/// Recursive `@import` resolver supporting Claude Code and Gemini CLI syntax with cycle and depth guards.
public struct ImportResolver: Sendable {
    /// Agent import dialect.
    public enum Syntax: String, Sendable, Codable, CaseIterable {
        case claudeCode
        case gemini
    }

    /// Default recursion hop limit matching Claude Code and Gemini CLI documentation.
    public static let defaultMaxDepth = 5

    /// Configured import syntax dialect.
    public var syntax: Syntax
    /// Maximum allowed hop depth from the root file (`0` = no imports expanded).
    public var maxDepth: Int

    /// Creates an `@import` resolver.
    public init(syntax: Syntax = .claudeCode, maxDepth: Int = Self.defaultMaxDepth) {
        self.syntax = syntax
        self.maxDepth = max(0, maxDepth)
    }

    /// Extracts `@import` directives from Markdown text while ignoring fenced code blocks and inline code spans.
    public static func extractImports(from markdown: String, startingAtLine: Int = 1) -> [ImportDirective] {
        let lines = splitLines(markdown)
        var directives: [ImportDirective] = []
        var activeFence: (char: Character, length: Int)?

        for (offset, line) in lines.enumerated() {
            let lineNumber = startingAtLine + offset
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = activeFence {
                if isClosingFence(trimmed, matching: fence) {
                    activeFence = nil
                }
                continue
            }

            if let opened = detectOpeningFence(trimmed) {
                activeFence = opened
                continue
            }

            directives.append(contentsOf: extractDirectivesFromLine(line, lineNumber: lineNumber))
        }

        return directives
    }

    /// Resolves `@import` directives starting from `rootURL` using injected `homeURL` and `fileSystem`.
    public func resolve(
        rootURL: URL,
        homeURL: URL,
        fileSystem: any ReadOnlyFileSystem
    ) -> ImportResolution {
        let standardizedRoot = rootURL.standardizedFileURL
        let rootRealPath = fileSystem.resolveSymlinks(standardizedRoot).standardizedFileURL.path

        let rootData: Data
        do {
            rootData = try fileSystem.contents(at: standardizedRoot)
        } catch {
            let diag = Diagnostic(
                code: "import.broken",
                severity: .error,
                message: "Cannot read root rules file '\(standardizedRoot.path)'",
                location: SourceLocation(path: standardizedRoot.path, realPath: rootRealPath)
            )
            return ImportResolution(
                rootURL: standardizedRoot,
                directImports: [],
                resolvedFiles: [],
                expandedContent: "",
                diagnostics: [diag]
            )
        }

        guard let rootMarkdown = String(data: rootData, encoding: .utf8) else {
            let diag = Diagnostic(
                code: "import.invalidUTF8",
                severity: .error,
                message: "Root rules file '\(standardizedRoot.path)' is not valid UTF-8",
                location: SourceLocation(path: standardizedRoot.path, realPath: rootRealPath)
            )
            return ImportResolution(
                rootURL: standardizedRoot,
                directImports: [],
                resolvedFiles: [],
                expandedContent: "",
                diagnostics: [diag]
            )
        }

        return resolve(
            markdown: rootMarkdown,
            sourceURL: standardizedRoot,
            homeURL: homeURL,
            fileSystem: fileSystem
        )
    }

    /// Resolves `@import` directives from an already-loaded Markdown string originating at `sourceURL`.
    public func resolve(
        markdown: String,
        sourceURL: URL,
        homeURL: URL,
        fileSystem: any ReadOnlyFileSystem
    ) -> ImportResolution {
        let standardizedSource = sourceURL.standardizedFileURL
        let rootRealPath = fileSystem.resolveSymlinks(standardizedSource).standardizedFileURL.path
        let directImports = Self.extractImports(from: markdown).map(\.path)

        var state = ResolutionState(
            homeURL: homeURL.standardizedFileURL,
            fileSystem: fileSystem,
            maxDepth: maxDepth,
            activeStack: [rootRealPath],
            expandedRealPaths: [rootRealPath]
        )

        let expanded = expandDocument(
            markdown: markdown,
            currentURL: standardizedSource,
            currentRealPath: rootRealPath,
            depth: 0,
            state: &state
        )

        return ImportResolution(
            rootURL: standardizedSource,
            directImports: directImports,
            resolvedFiles: state.resolvedFiles,
            expandedContent: expanded,
            diagnostics: state.diagnostics
        )
    }

    // MARK: - Recursive Expansion

    private struct ResolutionState {
        let homeURL: URL
        let fileSystem: any ReadOnlyFileSystem
        let maxDepth: Int
        var activeStack: Set<String>
        var expandedRealPaths: Set<String>
        var resolvedFiles: [URL] = []
        var diagnostics: [Diagnostic] = []
    }

    private func expandDocument(
        markdown: String,
        currentURL: URL,
        currentRealPath: String,
        depth: Int,
        state: inout ResolutionState
    ) -> String {
        let lines = Self.splitLines(markdown)
        var outputLines: [String] = []
        outputLines.reserveCapacity(lines.count)
        var activeFence: (char: Character, length: Int)?

        for (offset, line) in lines.enumerated() {
            let lineNumber = offset + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = activeFence {
                if Self.isClosingFence(trimmed, matching: fence) {
                    activeFence = nil
                }
                outputLines.append(line)
                continue
            }

            if let opened = Self.detectOpeningFence(trimmed) {
                activeFence = opened
                outputLines.append(line)
                continue
            }

            let directives = Self.extractDirectivesFromLine(line, lineNumber: lineNumber)
            guard !directives.isEmpty else {
                outputLines.append(line)
                continue
            }

            var appendedFragments: [String] = []
            for directive in directives {
                let nextDepth = depth + 1
                let siteLocation = SourceLocation(
                    path: currentURL.path,
                    realPath: currentRealPath,
                    lineRange: lineNumber...lineNumber
                )

                guard nextDepth <= state.maxDepth else {
                    state.diagnostics.append(
                        Diagnostic(
                            code: "import.maxDepthExceeded",
                            severity: .warning,
                            message: "Import '\(directive.path)' exceeds maximum depth of \(state.maxDepth)",
                            location: siteLocation
                        )
                    )
                    continue
                }

                let targetURL = resolveTargetURL(
                    path: directive.path,
                    relativeTo: currentURL,
                    homeURL: state.homeURL
                )
                let targetRealPath = state.fileSystem.resolveSymlinks(targetURL).standardizedFileURL.path

                if state.activeStack.contains(targetRealPath) {
                    state.diagnostics.append(
                        Diagnostic(
                            code: "import.cycle",
                            severity: .warning,
                            message: "Circular import detected for '\(directive.path)'",
                            location: siteLocation
                        )
                    )
                    continue
                }

                let targetData: Data
                do {
                    targetData = try state.fileSystem.contents(at: targetURL)
                } catch {
                    state.diagnostics.append(
                        Diagnostic(
                            code: "import.broken",
                            severity: .warning,
                            message: "Cannot read imported file '\(directive.path)'",
                            location: siteLocation
                        )
                    )
                    continue
                }

                guard let targetText = String(data: targetData, encoding: .utf8) else {
                    state.diagnostics.append(
                        Diagnostic(
                            code: "import.invalidUTF8",
                            severity: .warning,
                            message: "Imported file '\(directive.path)' is not valid UTF-8",
                            location: siteLocation
                        )
                    )
                    continue
                }

                // Diamond import deduplication: skip duplicate expansion without emitting a cycle warning.
                if state.expandedRealPaths.contains(targetRealPath) {
                    continue
                }

                state.expandedRealPaths.insert(targetRealPath)
                state.resolvedFiles.append(targetURL)
                state.activeStack.insert(targetRealPath)
                let childExpanded = expandDocument(
                    markdown: targetText,
                    currentURL: targetURL,
                    currentRealPath: targetRealPath,
                    depth: nextDepth,
                    state: &state
                )
                state.activeStack.remove(targetRealPath)
                appendedFragments.append(childExpanded)
            }

            if appendedFragments.isEmpty {
                outputLines.append(line)
            } else if Self.isStandaloneDirectiveLine(trimmed, directives: directives) {
                outputLines.append(contentsOf: appendedFragments)
            } else {
                outputLines.append(line)
                outputLines.append(contentsOf: appendedFragments)
            }
        }

        return outputLines.joined(separator: "\n")
    }

    private func resolveTargetURL(path: String, relativeTo currentFile: URL, homeURL: URL) -> URL {
        if path == "~" {
            return homeURL.standardizedFileURL
        }
        if path.hasPrefix("~/") {
            let relative = String(path.dropFirst(2))
            return homeURL.appendingPathComponent(relative).standardizedFileURL
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return
            currentFile
            .deletingLastPathComponent()
            .appendingPathComponent(path)
            .standardizedFileURL
    }

    // MARK: - Line Lexing

    private static func isStandaloneDirectiveLine(_ trimmed: String, directives: [ImportDirective]) -> Bool {
        guard directives.count == 1, let single = directives.first else { return false }
        var stripped = trimmed
        for bullet in ["- ", "* ", "+ "] where stripped.hasPrefix(bullet) {
            stripped = String(stripped.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return stripped == single.rawToken
    }

    private static func extractDirectivesFromLine(_ line: String, lineNumber: Int) -> [ImportDirective] {
        let chars = Array(line)
        var directives: [ImportDirective] = []
        var idx = 0

        while idx < chars.count {
            // Skip inline backtick code spans
            if chars[idx] == "`" {
                var tickCount = 0
                while idx + tickCount < chars.count && chars[idx + tickCount] == "`" {
                    tickCount += 1
                }
                if let closeIdx = findClosingTicks(in: chars, from: idx + tickCount, count: tickCount) {
                    idx = closeIdx + tickCount
                    continue
                }
                idx += tickCount
                continue
            }

            if chars[idx] == "@" {
                let prev = idx > 0 ? chars[idx - 1] : nil
                let validBoundary = prev == nil || prev?.isWhitespace == true || prev == "(" || prev == "["
                if validBoundary {
                    let (rawToken, unescapedPath, nextIndex, followedByOpenParen) = scanCandidateToken(
                        in: chars,
                        atIndex: idx
                    )
                    if !followedByOpenParen && isImportPathCandidate(unescapedPath) {
                        directives.append(
                            ImportDirective(
                                rawToken: rawToken,
                                path: unescapedPath,
                                line: lineNumber
                            )
                        )
                    }
                    idx = nextIndex
                    continue
                }
            }

            idx += 1
        }

        return directives
    }

    private static func scanCandidateToken(
        in chars: [Character],
        atIndex: Int
    ) -> (raw: String, unescaped: String, nextIndex: Int, followedByOpenParen: Bool) {
        var cursor = atIndex + 1
        var rawChars: [Character] = ["@"]
        var unescapedChars: [Character] = []

        while cursor < chars.count {
            let ch = chars[cursor]
            if ch == "\\" && cursor + 1 < chars.count && chars[cursor + 1] == " " {
                rawChars.append("\\")
                rawChars.append(" ")
                unescapedChars.append(" ")
                cursor += 2
                continue
            }

            if ch.isWhitespace || ch == "(" || ch == ")" || ch == "]" || ch == "`"
                || ch == "\"" || ch == "'" || ch == "<" || ch == ">"
            {
                break
            }

            rawChars.append(ch)
            unescapedChars.append(ch)
            cursor += 1
        }

        let followedByOpenParen = cursor < chars.count && chars[cursor] == "("

        // Trim trailing sentence punctuation (`,`, `;`, `:`, `!`, `?`, or `.` when not `./` or `..`)
        while let last = unescapedChars.last {
            if last == "," || last == ";" || last == ":" || last == "!" || last == "?" {
                unescapedChars.removeLast()
                rawChars.removeLast()
            } else if last == "." && unescapedChars.count > 1 && unescapedChars[unescapedChars.count - 2] != "." {
                unescapedChars.removeLast()
                rawChars.removeLast()
            } else {
                break
            }
        }

        return (String(rawChars), String(unescapedChars), cursor, followedByOpenParen)
    }

    private static func isImportPathCandidate(_ candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        if candidate.hasPrefix("./")
            || candidate.hasPrefix("../")
            || candidate.hasPrefix("~/")
            || candidate.hasPrefix("/")
        {
            return candidate.count > 1
        }
        return candidate.contains("/") || candidate.contains(".")
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

    private static func detectOpeningFence(_ trimmed: String) -> (char: Character, length: Int)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        if first == "`" && trimmed.dropFirst(count).contains("`") {
            return nil
        }
        return (first, count)
    }

    private static func isClosingFence(_ trimmed: String, matching fence: (char: Character, length: Int)) -> Bool {
        let count = trimmed.prefix { $0 == fence.char }.count
        guard count >= fence.length else { return false }
        return trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func splitLines(_ text: String) -> [String] {
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
}
