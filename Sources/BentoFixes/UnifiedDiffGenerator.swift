import BentoCore
import BentoParsing
import Foundation

/// Generates standard unified diff previews (`---` / `+++` / `@@ ... @@`) for `FixPlan` operations (`PLAN.md` §6.6, §6.7).
public enum UnifiedDiffGenerator {
    /// Builds `[UnifiedDiff]` previews for every operation in `plan` using `fileSystem` to read current file contents.
    public static func preview(
        plan: FixPlan,
        fileSystem: any ReadOnlyFileSystem,
        redactSecrets: Bool = false
    ) -> [UnifiedDiff] {
        var diffs: [UnifiedDiff] = []

        for op in plan.operations {
            switch op {
            case .writeFile(let path, let newBytes, _):
                let url = URL(fileURLWithPath: path)
                let oldData = (try? fileSystem.contents(at: url)) ?? Data()
                let existed = fileSystem.exists(url)
                let oldText = String(decoding: oldData, as: UTF8.self)
                let newText = String(decoding: newBytes, as: UTF8.self)
                let safeOld = redactSecrets ? redactSensitiveLines(oldText) : oldText
                let safeNew = redactSecrets ? redactSensitiveLines(newText) : newText
                let oldLabel = existed ? "a/\(path)" : "/dev/null"
                let patch = unifiedTextDiff(
                    oldLabel: oldLabel,
                    newLabel: "b/\(path)",
                    oldText: safeOld,
                    newText: safeNew
                )
                let summary = existed ? "Modify \(path)" : "Create \(path)"
                diffs.append(UnifiedDiff(path: path, summary: summary, patch: patch))

            case .symlink(let atPath, let destinationPath):
                let patch = """
                    --- a/\(atPath)
                    +++ b/\(atPath)
                    @@ -0,0 +1 @@
                    +symlink -> \(destinationPath)
                    """
                diffs.append(
                    UnifiedDiff(
                        path: atPath,
                        summary: "Symlink \(atPath) -> \(destinationPath)",
                        patch: patch
                    )
                )

            case .moveToTrash(let path, _):
                let patch = """
                    --- a/\(path)
                    +++ /dev/null
                    @@ -1 +0,0 @@
                    -move to Trash: \(path)
                    """
                diffs.append(
                    UnifiedDiff(
                        path: path,
                        summary: "Move \(path) to Trash",
                        patch: patch
                    )
                )

            case .moveItem(let fromPath, let toPath, _):
                let patch = """
                    --- a/\(fromPath)
                    +++ b/\(toPath)
                    @@ -1 +1 @@
                    -path: \(fromPath)
                    +path: \(toPath)
                    """
                diffs.append(
                    UnifiedDiff(
                        path: fromPath,
                        summary: "Move \(fromPath) -> \(toPath)",
                        patch: patch
                    )
                )

            case .mkdir(let path):
                let patch = """
                    --- /dev/null
                    +++ b/\(path)
                    @@ -0,0 +1 @@
                    +mkdir \(path)
                    """
                diffs.append(
                    UnifiedDiff(
                        path: path,
                        summary: "Create directory \(path)",
                        patch: patch
                    )
                )
            }
        }

        return diffs
    }

    /// Computes a standard unified diff with `contextLines` around edited hunks.
    public static func unifiedTextDiff(
        oldLabel: String,
        newLabel: String,
        oldText: String,
        newText: String,
        contextLines: Int = 3
    ) -> String {
        if oldText == newText {
            return ""
        }

        let oldLines = splitLines(oldText)
        let newLines = splitLines(newText)
        let edits = computeLCSEdits(oldLines: oldLines, newLines: newLines)

        let changedIndices = edits.indices.filter { edits[$0].kind != .equal }
        guard !changedIndices.isEmpty else {
            return ""
        }

        var groups: [ClosedRange<Int>] = []
        for idx in changedIndices {
            let lo = max(0, idx - contextLines)
            let hi = min(edits.count - 1, idx + contextLines)
            if let last = groups.last, lo <= last.upperBound + 1 {
                groups[groups.count - 1] = last.lowerBound...max(last.upperBound, hi)
            } else {
                groups.append(lo...hi)
            }
        }

        var out: [String] = [
            "--- \(oldLabel)",
            "+++ \(newLabel)"
        ]

        for group in groups {
            let slice = edits[group]
            let oldStart =
                slice.first(where: { $0.oldLine != nil })?.oldLine
                ?? (group.lowerBound > 0 ? (edits[..<group.lowerBound].compactMap(\.oldLine).last ?? 0) + 1 : 1)
            let newStart =
                slice.first(where: { $0.newLine != nil })?.newLine
                ?? (group.lowerBound > 0 ? (edits[..<group.lowerBound].compactMap(\.newLine).last ?? 0) + 1 : 1)
            let oldCount = slice.filter { $0.kind != .insert }.count
            let newCount = slice.filter { $0.kind != .delete }.count

            let displayOldStart = oldCount == 0 ? max(0, oldStart - 1) : oldStart
            let displayNewStart = newCount == 0 ? max(0, newStart - 1) : newStart
            out.append("@@ -\(displayOldStart),\(oldCount) +\(displayNewStart),\(newCount) @@")

            for edit in slice {
                switch edit.kind {
                case .equal:
                    out.append(" \(edit.text)")
                case .delete:
                    out.append("-\(edit.text)")
                case .insert:
                    out.append("+\(edit.text)")
                }
            }
        }

        return out.joined(separator: "\n")
    }

    /// Generates a multi-file unified diff between two skill directories (`PLAN.md` §6.6).
    static func directoryTreeDiff(dirA: URL, dirB: URL) throws -> String {
        let filesA = Set(try DirectoryHasher.listRelativeFilePaths(under: dirA))
        let filesB = Set(try DirectoryHasher.listRelativeFilePaths(under: dirB))
        let allRel = filesA.union(filesB).sorted()

        var patches: [String] = []
        for rel in allRel {
            let urlA = dirA.appendingPathComponent(rel)
            let urlB = dirB.appendingPathComponent(rel)
            let textA =
                filesA.contains(rel)
                ? ((try? String(contentsOf: urlA, encoding: .utf8)) ?? "<binary or non-UTF8>")
                : ""
            let textB =
                filesB.contains(rel)
                ? ((try? String(contentsOf: urlB, encoding: .utf8)) ?? "<binary or non-UTF8>")
                : ""
            guard textA != textB else { continue }
            let patch = unifiedTextDiff(
                oldLabel: "\(dirA.path)/\(rel)",
                newLabel: "\(dirB.path)/\(rel)",
                oldText: textA,
                newText: textB
            )
            if !patch.isEmpty {
                patches.append(patch)
            }
        }
        return patches.joined(separator: "\n")
    }

    // MARK: - LCS Diff Helpers

    private enum EditKind {
        case equal
        case delete
        case insert
    }

    private struct LineEdit {
        var kind: EditKind
        var text: String
        var oldLine: Int?
        var newLine: Int?
    }

    private static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if normalized.hasSuffix("\n") && lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    private static func computeLCSEdits(oldLines: [String], newLines: [String]) -> [LineEdit] {
        // Trim shared prefix and suffix so typical minimal edits run in O(changed_lines^2) instead of O(N*M).
        var prefixCount = 0
        let minCount = min(oldLines.count, newLines.count)
        while prefixCount < minCount && oldLines[prefixCount] == newLines[prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < (minCount - prefixCount)
            && oldLines[oldLines.count - 1 - suffixCount] == newLines[newLines.count - 1 - suffixCount]
        {
            suffixCount += 1
        }

        var result: [LineEdit] = []
        result.reserveCapacity(oldLines.count + newLines.count)

        for i in 0..<prefixCount {
            result.append(LineEdit(kind: .equal, text: oldLines[i], oldLine: i + 1, newLine: i + 1))
        }

        let midOld = Array(oldLines[prefixCount..<(oldLines.count - suffixCount)])
        let midNew = Array(newLines[prefixCount..<(newLines.count - suffixCount)])

        if midOld.count * midNew.count <= 250_000 {
            let n = midOld.count
            let m = midNew.count
            var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
            if n > 0 && m > 0 {
                for i in stride(from: n - 1, through: 0, by: -1) {
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        if midOld[i] == midNew[j] {
                            dp[i][j] = dp[i + 1][j + 1] + 1
                        } else {
                            dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                        }
                    }
                }
            }
            var i = 0
            var j = 0
            while i < n || j < m {
                if i < n && j < m && midOld[i] == midNew[j] {
                    result.append(
                        LineEdit(
                            kind: .equal,
                            text: midOld[i],
                            oldLine: prefixCount + i + 1,
                            newLine: prefixCount + j + 1
                        )
                    )
                    i += 1
                    j += 1
                } else if j == m || (i < n && dp[i + 1][j] >= dp[i][j + 1]) {
                    result.append(
                        LineEdit(
                            kind: .delete,
                            text: midOld[i],
                            oldLine: prefixCount + i + 1,
                            newLine: nil
                        )
                    )
                    i += 1
                } else {
                    result.append(
                        LineEdit(
                            kind: .insert,
                            text: midNew[j],
                            oldLine: nil,
                            newLine: prefixCount + j + 1
                        )
                    )
                    j += 1
                }
            }
        } else {
            for (idx, line) in midOld.enumerated() {
                result.append(LineEdit(kind: .delete, text: line, oldLine: prefixCount + idx + 1, newLine: nil))
            }
            for (idx, line) in midNew.enumerated() {
                result.append(LineEdit(kind: .insert, text: line, oldLine: nil, newLine: prefixCount + idx + 1))
            }
        }

        let oldSuffixStart = oldLines.count - suffixCount
        let newSuffixStart = newLines.count - suffixCount
        for k in 0..<suffixCount {
            result.append(
                LineEdit(
                    kind: .equal,
                    text: oldLines[oldSuffixStart + k],
                    oldLine: oldSuffixStart + k + 1,
                    newLine: newSuffixStart + k + 1
                )
            )
        }

        return result
    }

    private static func redactSensitiveLines(_ text: String) -> String {
        let pattern = "(?i)(\"[^\"]*(?:key|token|secret|password|authorization)[^\"]*\"\\s*:\\s*\")([^\"]+)(\")"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "$1\(SecretRedactor.marker)$3"
        )
    }
}
