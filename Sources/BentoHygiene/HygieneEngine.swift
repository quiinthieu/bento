import BentoCore
import BentoParsing
import BentoTokenizer
import Foundation

/// Cross-agent rules and configuration hygiene engine (`PLAN.md` §6.5, §9, §11 T13).
public struct HygieneEngine: Sendable {
    private static let privateAgentDirectories: Set<String> = [
        ".claude",
        ".codex",
        ".gemini",
        ".copilot",
        ".cursor",
        ".windsurf",
        ".codeium",
        ".github",
        ".agents"
    ]

    /// Hygiene thresholds and parameters.
    public var config: HygieneConfig
    private let conflictCatalog: ConflictCatalogDocument?

    /// Creates a hygiene engine with configurable thresholds and optional custom conflict catalog.
    public init(
        config: HygieneConfig = HygieneConfig(),
        conflictCatalog: ConflictCatalogDocument? = nil
    ) {
        self.config = config
        self.conflictCatalog = conflictCatalog
    }

    /// Audits a workspace `Snapshot` (optionally scoped to `agentFilter` and/or `repoFilter`) and returns
    /// deterministically ordered `Finding` records.
    public func audit(
        snapshot: Snapshot,
        fixSupports: [AgentID: FixSupport] = [:],
        fileSystem: (any ReadOnlyFileSystem)? = nil,
        tokenizer: (any TokenCountingProvider)? = nil,
        agentFilter: AgentID? = nil,
        repoFilter: String? = nil
    ) throws -> [Finding] {
        let canonicalRepo = repoFilter.map { snapshot.resolveCanonicalRepoPath($0) }
        let selectedArtifacts = snapshot.artifacts(agent: nil, repoPath: canonicalRepo)
        let selectedResolutions = snapshot.resolutions.filter { res in
            if let canonicalRepo, res.folder != canonicalRepo {
                return false
            }
            return true
        }

        let allFindings = try audit(
            artifacts: selectedArtifacts,
            resolutions: selectedResolutions,
            repos: snapshot.repos,
            homePath: snapshot.homePath,
            fixSupports: fixSupports,
            fileSystem: fileSystem,
            tokenizer: tokenizer
        )

        guard let agentFilter else {
            return allFindings
        }
        let agentArtifactIDs = Set(selectedArtifacts.lazy.filter { $0.agent == agentFilter }.map(\.id))
        return allFindings.filter { finding in
            finding.artifacts.contains { agentArtifactIDs.contains($0) }
        }
    }

    /// Audits a list of discovered `Artifact` and `Resolution` records and returns deterministically ordered `Finding` records.
    public func audit(
        artifacts: [Artifact],
        resolutions: [Resolution] = [],
        repos: [DiscoveredRepo] = [],
        homePath: String? = nil,
        fixSupports: [AgentID: FixSupport] = [:],
        fileSystem: (any ReadOnlyFileSystem)? = nil,
        tokenizer: (any TokenCountingProvider)? = nil
    ) throws -> [Finding] {
        let catalog = try conflictCatalog ?? ConflictCatalog.loadDefault()
        let conflictDetector = ConflictDetector(catalog: catalog)
        let homePrefixes = Self.computeHomePrefixes(homePath: homePath, fileSystem: fileSystem)

        let physicalRuleFiles = extractPhysicalRuleFiles(
            from: artifacts,
            repos: repos,
            homePrefixes: homePrefixes,
            fileSystem: fileSystem
        )

        var indexedUnits: [IndexedRuleUnit] = []
        for (fileIndex, file) in physicalRuleFiles.enumerated() {
            for unit in file.units {
                let stances = conflictDetector.extractStances(for: unit.normalizedText)
                let shingles = MinHashLSH.shingles(
                    for: unit.normalizedText,
                    wordCount: config.shingleWordCount
                )
                indexedUnits.append(
                    IndexedRuleUnit(
                        fileIndex: fileIndex,
                        unit: unit,
                        stances: stances,
                        shingles: shingles
                    )
                )
            }
        }

        var findings: [Finding] = []

        // 1. Exact duplicate rule units across comparable physical rule files.
        findings.append(
            contentsOf: detectExactRuleDuplicates(
                files: physicalRuleFiles,
                units: indexedUnits
            )
        )

        // 2. Identical non-symlinked skill directories across comparable scopes.
        findings.append(
            contentsOf: detectDuplicateSkills(
                artifacts: artifacts,
                repos: repos,
                homePrefixes: homePrefixes,
                fixSupports: fixSupports
            )
        )

        // 3. Deterministic opposing directive conflicts (`conflicts.yaml`).
        let (conflictFindings, conflictingUnitPairs) = detectConflicts(
            files: physicalRuleFiles,
            units: indexedUnits
        )
        findings.append(contentsOf: conflictFindings)

        // 4. MinHash-LSH near-duplicate rule units (`Jaccard >= nearDuplicateJaccardThreshold`).
        let (nearDupFindings, nearDupUnitPairs) = detectNearDuplicates(
            files: physicalRuleFiles,
            units: indexedUnits,
            conflictingUnitPairs: conflictingUnitPairs
        )
        findings.append(contentsOf: nearDupFindings)

        // 5. Block-level `>= 70%` overlap `@AGENTS.md` import suggestions (checked against `FixSupport`).
        findings.append(
            contentsOf: detectBlockLevelImportSuggestions(
                files: physicalRuleFiles,
                units: indexedUnits,
                nearDupUnitPairs: nearDupUnitPairs,
                fixSupports: fixSupports,
                homePath: homePath,
                fileSystem: fileSystem
            )
        )

        // 6. Size limits, broken `@imports`, and invalid configuration diagnostics.
        findings.append(
            contentsOf: detectDiagnosticAndLimitFindings(
                artifacts: artifacts,
                resolutions: resolutions,
                physicalRuleFiles: physicalRuleFiles,
                homePrefixes: homePrefixes,
                tokenizer: tokenizer
            )
        )

        return Self.deduplicateAndSort(findings)
    }

    // MARK: - Internal Models

    private struct UnitPair: Hashable {
        var first: Int
        var second: Int

        init(_ a: Int, _ b: Int) {
            self.first = min(a, b)
            self.second = max(a, b)
        }
    }

    private struct PhysicalRuleFile {
        var path: String
        var realPath: String
        var identityPath: String
        var repoRoot: String?
        var agents: Set<AgentID>
        var artifactIDs: [ArtifactID]
        var hasAlwaysOnArtifact: Bool
        var directImports: [String]
        var rawContentForTokens: String
        var contentHash: String
        var units: [RuleUnit]
        var isCanonicalSharedAgentsFile: Bool
    }

    private struct IndexedRuleUnit {
        var fileIndex: Int
        var unit: RuleUnit
        var stances: [ConflictDetector.UnitStance]
        var shingles: Set<UInt64>
    }

    // MARK: - Step 0: Physical Rule File Extraction

    private func extractPhysicalRuleFiles(
        from artifacts: [Artifact],
        repos: [DiscoveredRepo],
        homePrefixes: [String],
        fileSystem: (any ReadOnlyFileSystem)?
    ) -> [PhysicalRuleFile] {
        var grouped: [String: [Artifact]] = [:]
        for artifact in artifacts where artifact.kind == .rules && artifact.enabled {
            guard case .rules = artifact.payload else { continue }
            grouped[artifact.location.realPath, default: []].append(artifact)
        }

        var files: [PhysicalRuleFile] = []
        files.reserveCapacity(grouped.count)

        for realPath in grouped.keys.sorted() {
            guard let group = grouped[realPath], !group.isEmpty else { continue }
            let sortedGroup = group.sorted { lhs, rhs in
                if lhs.location.path != rhs.location.path {
                    return lhs.location.path < rhs.location.path
                }
                return lhs.id.rawValue < rhs.id.rawValue
            }
            let primary = sortedGroup[0]
            guard case .rules(let primaryDoc) = primary.payload else { continue }

            let displayPath = primary.location.path
            let identityPath = Self.makeIdentityPath(displayPath, homePrefixes: homePrefixes)
            let agents = Set(sortedGroup.map(\.agent))
            let artifactIDs = Array(Set(sortedGroup.map(\.id))).sorted { $0.rawValue < $1.rawValue }
            let hasAlwaysOn = sortedGroup.contains { $0.loadMode == .always }
            let directImports = Array(
                Set(
                    sortedGroup.flatMap { art -> [String] in
                        if case .rules(let doc) = art.payload {
                            return doc.imports
                        }
                        return []
                    }
                )
            ).sorted()

            let repoRoot = Self.inferRepoRoot(
                for: sortedGroup,
                path: displayPath,
                realPath: realPath,
                repos: repos
            )

            let rawDocumentText: String
            let splitUnits: [RuleUnit]
            if let fileSystem,
                let rawData = try? fileSystem.contents(at: URL(fileURLWithPath: displayPath)),
                let decoded = String(data: rawData, encoding: .utf8)
            {
                rawDocumentText = decoded
                splitUnits = MarkdownRuleSplitter.splitDocument(decoded)
            } else {
                rawDocumentText = primaryDoc.content
                splitUnits = MarkdownRuleSplitter.splitDocument(primaryDoc.content)
            }

            let filteredUnits = splitUnits.filter { !Self.isPureImportDirectiveUnit($0) }
            let isSharedAgents = Self.isSharedAgentsMarkdownPath(displayPath, repoRoot: repoRoot)

            files.append(
                PhysicalRuleFile(
                    path: displayPath,
                    realPath: realPath,
                    identityPath: identityPath,
                    repoRoot: repoRoot,
                    agents: agents,
                    artifactIDs: artifactIDs,
                    hasAlwaysOnArtifact: hasAlwaysOn,
                    directImports: directImports,
                    rawContentForTokens: rawDocumentText,
                    contentHash: primary.contentHash,
                    units: filteredUnits,
                    isCanonicalSharedAgentsFile: isSharedAgents
                )
            )
        }

        files.sort { $0.identityPath < $1.identityPath }
        return files
    }

    private static func isPureImportDirectiveUnit(_ unit: RuleUnit) -> Bool {
        let directives = ImportResolver.extractImports(from: unit.rawText)
        guard !directives.isEmpty else { return false }

        var remainder = unit.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["- ", "* ", "+ "] where remainder.hasPrefix(prefix) {
            remainder = String(remainder.dropFirst(prefix.count))
            break
        }
        for directive in directives {
            if let range = remainder.range(of: directive.rawToken) {
                remainder.removeSubrange(range)
            }
        }
        return remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isSharedAgentsMarkdownPath(_ path: String, repoRoot: String?) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.lastPathComponent == "AGENTS.md", let repoRoot else {
            return false
        }
        let stdRepo = URL(fileURLWithPath: repoRoot).standardizedFileURL.path
        guard url.path.hasPrefix(stdRepo + "/") else {
            return false
        }
        let rel = String(url.path.dropFirst(stdRepo.count + 1))
        let components = rel.split(separator: "/").dropLast()
        return !components.contains { privateAgentDirectories.contains(String($0)) || $0.hasPrefix(".") }
    }

    private static func areComparable(_ lhs: PhysicalRuleFile, _ rhs: PhysicalRuleFile) -> Bool {
        guard lhs.realPath != rhs.realPath else { return false }
        if lhs.repoRoot == nil && rhs.repoRoot == nil {
            return true
        }
        if let leftRepo = lhs.repoRoot, let rightRepo = rhs.repoRoot {
            return leftRepo == rightRepo
        }
        return !lhs.agents.isDisjoint(with: rhs.agents)
    }

    // MARK: - Step 1: Exact Rule Duplicates

    private func detectExactRuleDuplicates(
        files: [PhysicalRuleFile],
        units: [IndexedRuleUnit]
    ) -> [Finding] {
        var byNormalizedText: [String: [Int]] = [:]
        var seenFileForNorm: [String: Set<Int>] = [:]

        for (unitIdx, item) in units.enumerated() {
            let norm = item.unit.normalizedText
            guard !norm.isEmpty else { continue }
            if seenFileForNorm[norm, default: []].insert(item.fileIndex).inserted {
                byNormalizedText[norm, default: []].append(unitIdx)
            }
        }

        var findings: [Finding] = []
        for norm in byNormalizedText.keys.sorted() {
            guard let occurrenceIndices = byNormalizedText[norm], occurrenceIndices.count >= 2 else {
                continue
            }

            let components = connectedComponents(items: occurrenceIndices) { idxA, idxB in
                Self.areComparable(files[units[idxA].fileIndex], files[units[idxB].fileIndex])
            }

            for component in components where component.count >= 2 {
                let sortedOccurrences = component.sorted { idxA, idxB in
                    let fileA = files[units[idxA].fileIndex]
                    let fileB = files[units[idxB].fileIndex]
                    if fileA.identityPath != fileB.identityPath {
                        return fileA.identityPath < fileB.identityPath
                    }
                    return units[idxA].unit.lineRange.lowerBound < units[idxB].unit.lineRange.lowerBound
                }

                let spans = sortedOccurrences.map { idx in
                    let file = files[units[idx].fileIndex]
                    return SourceLocation(
                        path: file.path,
                        realPath: file.realPath,
                        lineRange: units[idx].unit.lineRange
                    )
                }
                let identitySpanTokens = sortedOccurrences.map { idx in
                    let file = files[units[idx].fileIndex]
                    let range = units[idx].unit.lineRange
                    return "\(file.identityPath):\(range.lowerBound)-\(range.upperBound)"
                }
                let artifactIDs = Array(
                    Set(sortedOccurrences.flatMap { files[units[$0].fileIndex].artifactIDs })
                ).sorted { $0.rawValue < $1.rawValue }

                let sampleRaw = Self.singleLinePreview(units[sortedOccurrences[0]].unit.rawText)
                let fileNames = sortedOccurrences.map {
                    URL(fileURLWithPath: files[units[$0].fileIndex].path).lastPathComponent
                }
                let findingID = Self.hashFindingID(
                    "exactDuplicate|\(norm)|\(identitySpanTokens.joined(separator: ","))"
                )
                let message =
                    "Exact duplicate rule across \(spans.count) files (\(fileNames.joined(separator: ", "))): \"\(sampleRaw)\""

                findings.append(
                    Finding(
                        id: findingID,
                        kind: .exactDuplicate,
                        severity: .warning,
                        artifacts: artifactIDs,
                        spans: spans,
                        message: message
                    )
                )
            }
        }

        return findings
    }

    // MARK: - Step 2: Identical Non-Symlinked Skills

    private func detectDuplicateSkills(
        artifacts: [Artifact],
        repos: [DiscoveredRepo],
        homePrefixes: [String],
        fixSupports: [AgentID: FixSupport]
    ) -> [Finding] {
        struct PhysicalSkillDir {
            var skillDirRealPath: String
            var manifestPath: String
            var manifestRealPath: String
            var identityPath: String
            var repoRoot: String?
            var agents: Set<AgentID>
            var artifactIDs: [ArtifactID]
            var name: String
            var contentSignature: String
        }

        var byDirRealPath: [String: [Artifact]] = [:]
        for artifact in artifacts where artifact.kind == .skill && artifact.enabled {
            guard case .skill = artifact.payload else { continue }
            let dirRealPath = URL(fileURLWithPath: artifact.location.realPath)
                .deletingLastPathComponent()
                .standardizedFileURL
                .path
            byDirRealPath[dirRealPath, default: []].append(artifact)
        }

        var physicalSkills: [PhysicalSkillDir] = []
        for dirRealPath in byDirRealPath.keys.sorted() {
            guard let group = byDirRealPath[dirRealPath], !group.isEmpty else { continue }
            let sorted = group.sorted { $0.location.path < $1.location.path }
            let primary = sorted[0]
            guard case .skill(let skillDoc) = primary.payload else { continue }

            let identityPath = Self.makeIdentityPath(primary.location.path, homePrefixes: homePrefixes)
            let repoRoot = Self.inferRepoRoot(
                for: sorted,
                path: primary.location.path,
                realPath: primary.location.realPath,
                repos: repos
            )
            let signature = "\(primary.contentHash)|\(skillDoc.supportingFiles.sorted().joined(separator: ","))"

            physicalSkills.append(
                PhysicalSkillDir(
                    skillDirRealPath: dirRealPath,
                    manifestPath: primary.location.path,
                    manifestRealPath: primary.location.realPath,
                    identityPath: identityPath,
                    repoRoot: repoRoot,
                    agents: Set(sorted.map(\.agent)),
                    artifactIDs: Array(Set(sorted.map(\.id))).sorted { $0.rawValue < $1.rawValue },
                    name: skillDoc.name,
                    contentSignature: signature
                )
            )
        }

        var bySignature: [String: [Int]] = [:]
        for (idx, item) in physicalSkills.enumerated() {
            bySignature[item.contentSignature, default: []].append(idx)
        }

        var findings: [Finding] = []
        for sig in bySignature.keys.sorted() {
            guard let indices = bySignature[sig], indices.count >= 2 else { continue }
            let components = connectedComponents(items: indices) { a, b in
                let lhs = physicalSkills[a]
                let rhs = physicalSkills[b]
                guard lhs.skillDirRealPath != rhs.skillDirRealPath else { return false }
                if lhs.repoRoot == nil && rhs.repoRoot == nil { return true }
                if let lr = lhs.repoRoot, let rr = rhs.repoRoot { return lr == rr }
                return !lhs.agents.isDisjoint(with: rhs.agents)
            }

            for component in components where component.count >= 2 {
                let sortedIndices = component.sorted {
                    physicalSkills[$0].identityPath < physicalSkills[$1].identityPath
                }
                let spans = sortedIndices.map { idx in
                    SourceLocation(
                        path: physicalSkills[idx].manifestPath,
                        realPath: physicalSkills[idx].manifestRealPath
                    )
                }
                let artifactIDs = Array(
                    Set(sortedIndices.flatMap { physicalSkills[$0].artifactIDs })
                ).sorted { $0.rawValue < $1.rawValue }
                let allAgents = sortedIndices.reduce(into: Set<AgentID>()) { acc, idx in
                    acc.formUnion(physicalSkills[idx].agents)
                }
                let supportsSymlink = allAgents.contains {
                    fixSupports[$0]?.supportedKinds.contains(.consolidateSkillsViaSymlink) == true
                }
                let suggestedFixes: [FixKind] = supportsSymlink ? [.consolidateSkillsViaSymlink] : []
                let skillName = physicalSkills[sortedIndices[0]].name
                let idPaths = sortedIndices.map { physicalSkills[$0].identityPath }.joined(separator: ",")
                let findingID = Self.hashFindingID("exactDuplicateSkill|\(sig)|\(idPaths)")

                findings.append(
                    Finding(
                        id: findingID,
                        kind: .exactDuplicate,
                        severity: .warning,
                        artifacts: artifactIDs,
                        spans: spans,
                        message:
                            "Identical non-symlinked skill '\(skillName)' duplicated across \(spans.count) directories.",
                        suggestedFixes: suggestedFixes
                    )
                )
            }
        }

        return findings
    }

    // MARK: - Step 3: Opposing Directive Conflicts

    private func detectConflicts(
        files: [PhysicalRuleFile],
        units: [IndexedRuleUnit]
    ) -> (findings: [Finding], conflictingPairs: Set<UnitPair>) {
        struct ConflictGroupAccumulator {
            var ruleID: String
            var topic: String
            var leftNorm: String
            var leftStance: String
            var rightNorm: String
            var rightStance: String
            var leftUnitIndices: Set<Int>
            var rightUnitIndices: Set<Int>
        }

        var conflictingPairs: Set<UnitPair> = []
        var groupedConflicts: [String: ConflictGroupAccumulator] = [:]

        guard units.count >= 2 else { return ([], []) }

        for i in 0..<(units.count - 1) where !units[i].stances.isEmpty {
            let unitA = units[i]
            let fileA = files[unitA.fileIndex]

            for j in (i + 1)..<units.count where !units[j].stances.isEmpty {
                let unitB = units[j]
                let fileB = files[unitB.fileIndex]
                guard Self.areComparable(fileA, fileB) else { continue }

                for stanceA in unitA.stances {
                    for stanceB in unitB.stances where ConflictDetector.areConflicting(stanceA, stanceB) {
                        conflictingPairs.insert(UnitPair(i, j))

                        let scopeTag = fileA.repoRoot ?? fileB.repoRoot ?? "<global>"
                        let normA = unitA.unit.normalizedText
                        let normB = unitB.unit.normalizedText

                        let (leftNorm, leftStance, leftIdx, rightNorm, rightStance, rightIdx):
                            (String, String, Int, String, String, Int)
                        if (stanceA.stanceLabel, normA) <= (stanceB.stanceLabel, normB) {
                            (leftNorm, leftStance, leftIdx, rightNorm, rightStance, rightIdx) =
                                (normA, stanceA.stanceLabel, i, normB, stanceB.stanceLabel, j)
                        } else {
                            (leftNorm, leftStance, leftIdx, rightNorm, rightStance, rightIdx) =
                                (normB, stanceB.stanceLabel, j, normA, stanceA.stanceLabel, i)
                        }

                        let groupKey = "\(scopeTag)|\(stanceA.ruleID)|\(leftNorm)|\(rightNorm)"
                        if var existing = groupedConflicts[groupKey] {
                            existing.leftUnitIndices.insert(leftIdx)
                            existing.rightUnitIndices.insert(rightIdx)
                            groupedConflicts[groupKey] = existing
                        } else {
                            groupedConflicts[groupKey] = ConflictGroupAccumulator(
                                ruleID: stanceA.ruleID,
                                topic: stanceA.topic,
                                leftNorm: leftNorm,
                                leftStance: leftStance,
                                rightNorm: rightNorm,
                                rightStance: rightStance,
                                leftUnitIndices: [leftIdx],
                                rightUnitIndices: [rightIdx]
                            )
                        }
                    }
                }
            }
        }

        func selectCanonicalRepresentative(_ indices: Set<Int>) -> Int {
            indices.sorted { a, b in
                let fileA = files[units[a].fileIndex]
                let fileB = files[units[b].fileIndex]
                if fileA.isCanonicalSharedAgentsFile != fileB.isCanonicalSharedAgentsFile {
                    return fileA.isCanonicalSharedAgentsFile
                }
                if fileA.identityPath != fileB.identityPath {
                    return fileA.identityPath < fileB.identityPath
                }
                return units[a].unit.lineRange.lowerBound < units[b].unit.lineRange.lowerBound
            }[0]
        }

        var findings: [Finding] = []
        for key in groupedConflicts.keys.sorted() {
            guard let group = groupedConflicts[key] else { continue }
            let repLeft = selectCanonicalRepresentative(group.leftUnitIndices)
            let repRight = selectCanonicalRepresentative(group.rightUnitIndices)

            let orderedReps = [repLeft, repRight].sorted { a, b in
                let fileA = files[units[a].fileIndex]
                let fileB = files[units[b].fileIndex]
                if fileA.identityPath != fileB.identityPath {
                    return fileA.identityPath < fileB.identityPath
                }
                return units[a].unit.lineRange.lowerBound < units[b].unit.lineRange.lowerBound
            }

            let firstIdx = orderedReps[0]
            let secondIdx = orderedReps[1]
            let firstFile = files[units[firstIdx].fileIndex]
            let secondFile = files[units[secondIdx].fileIndex]

            let firstSpan = SourceLocation(
                path: firstFile.path,
                realPath: firstFile.realPath,
                lineRange: units[firstIdx].unit.lineRange
            )
            let secondSpan = SourceLocation(
                path: secondFile.path,
                realPath: secondFile.realPath,
                lineRange: units[secondIdx].unit.lineRange
            )

            let allParticipatingIndices = group.leftUnitIndices.union(group.rightUnitIndices)
            let artifactIDs = Array(
                Set(allParticipatingIndices.flatMap { files[units[$0].fileIndex].artifactIDs })
            ).sorted { $0.rawValue < $1.rawValue }

            let firstPreview = Self.singleLinePreview(units[firstIdx].unit.rawText)
            let secondPreview = Self.singleLinePreview(units[secondIdx].unit.rawText)
            let firstFileName = URL(fileURLWithPath: firstFile.path).lastPathComponent
            let secondFileName = URL(fileURLWithPath: secondFile.path).lastPathComponent

            let idSeed =
                "conflict|\(group.ruleID)|\(firstFile.identityPath):\(units[firstIdx].unit.lineRange.lowerBound)"
                + "|\(secondFile.identityPath):\(units[secondIdx].unit.lineRange.lowerBound)"
            let findingID = Self.hashFindingID(idSeed)

            let message =
                "Conflicting \(group.topic) directives between \(firstFileName) and \(secondFileName): "
                + "\"\(firstPreview)\" vs \"\(secondPreview)\""

            findings.append(
                Finding(
                    id: findingID,
                    kind: .conflict,
                    severity: .warning,
                    artifacts: artifactIDs,
                    spans: [firstSpan, secondSpan],
                    message: message
                )
            )
        }

        return (findings, conflictingPairs)
    }

    // MARK: - Step 4: Near-Duplicate Detection (`MinHash-LSH`)

    private func detectNearDuplicates(
        files: [PhysicalRuleFile],
        units: [IndexedRuleUnit],
        conflictingUnitPairs: Set<UnitPair>
    ) -> (findings: [Finding], verifiedPairs: [UnitPair: Double]) {
        guard units.count >= 2 else { return ([], [:]) }

        let lsh = MinHashLSH(
            permutations: config.minHashPermutations,
            bands: config.lshBands
        )
        let signatures = units.map { lsh.signature(for: $0.shingles) }
        let candidates = lsh.candidatePairs(for: signatures)

        var verifiedPairs: [UnitPair: Double] = [:]
        var participatingIndicesSet: Set<Int> = []

        for (i, j) in candidates {
            let unitA = units[i]
            let unitB = units[j]
            guard unitA.fileIndex != unitB.fileIndex else { continue }
            guard unitA.unit.normalizedText != unitB.unit.normalizedText else { continue }
            guard Self.areComparable(files[unitA.fileIndex], files[unitB.fileIndex]) else { continue }

            let pair = UnitPair(i, j)
            guard !conflictingUnitPairs.contains(pair) else { continue }

            let similarity = MinHashLSH.jaccard(unitA.shingles, unitB.shingles)
            if similarity >= config.nearDuplicateJaccardThreshold {
                verifiedPairs[pair] = similarity
                participatingIndicesSet.insert(i)
                participatingIndicesSet.insert(j)
            }
        }

        guard !verifiedPairs.isEmpty else { return ([], [:]) }

        let participating = participatingIndicesSet.sorted()
        let components = connectedComponents(items: participating) { a, b in
            verifiedPairs[UnitPair(a, b)] != nil
        }

        var findings: [Finding] = []
        for component in components where component.count >= 2 {
            // Keep at most one unit per physical file in a single near-duplicate cluster.
            var byFile: [Int: Int] = [:]
            for idx in component.sorted() {
                let fIdx = units[idx].fileIndex
                if let existing = byFile[fIdx] {
                    if units[idx].unit.lineRange.lowerBound < units[existing].unit.lineRange.lowerBound {
                        byFile[fIdx] = idx
                    }
                } else {
                    byFile[fIdx] = idx
                }
            }
            guard byFile.count >= 2 else { continue }

            let sortedUnitIndices = byFile.values.sorted { a, b in
                let fileA = files[units[a].fileIndex]
                let fileB = files[units[b].fileIndex]
                if fileA.identityPath != fileB.identityPath {
                    return fileA.identityPath < fileB.identityPath
                }
                return units[a].unit.lineRange.lowerBound < units[b].unit.lineRange.lowerBound
            }

            var maxSimilarity = config.nearDuplicateJaccardThreshold
            for a in 0..<(sortedUnitIndices.count - 1) {
                for b in (a + 1)..<sortedUnitIndices.count {
                    if let sim = verifiedPairs[UnitPair(sortedUnitIndices[a], sortedUnitIndices[b])],
                        sim > maxSimilarity
                    {
                        maxSimilarity = sim
                    }
                }
            }

            let spans = sortedUnitIndices.map { idx in
                let file = files[units[idx].fileIndex]
                return SourceLocation(
                    path: file.path,
                    realPath: file.realPath,
                    lineRange: units[idx].unit.lineRange
                )
            }
            let idTokens = sortedUnitIndices.map { idx in
                let file = files[units[idx].fileIndex]
                let r = units[idx].unit.lineRange
                return "\(file.identityPath):\(r.lowerBound)-\(r.upperBound)"
            }
            let artifactIDs = Array(
                Set(sortedUnitIndices.flatMap { files[units[$0].fileIndex].artifactIDs })
            ).sorted { $0.rawValue < $1.rawValue }

            let pct = Int((maxSimilarity * 100.0).rounded())
            let preview = Self.singleLinePreview(units[sortedUnitIndices[0]].unit.rawText)
            let findingID = Self.hashFindingID("nearDuplicate|\(idTokens.joined(separator: ","))")

            findings.append(
                Finding(
                    id: findingID,
                    kind: .nearDuplicate,
                    severity: .warning,
                    artifacts: artifactIDs,
                    spans: spans,
                    message:
                        "Near-duplicate rule (\(pct)% shingle Jaccard similarity) across \(spans.count) files: \"\(preview)\""
                )
            )
        }

        return (findings, verifiedPairs)
    }

    // MARK: - Step 5: Block-Level `>= 70%` `@AGENTS.md` Import Suggestion

    private func detectBlockLevelImportSuggestions(
        files: [PhysicalRuleFile],
        units: [IndexedRuleUnit],
        nearDupUnitPairs: [UnitPair: Double],
        fixSupports: [AgentID: FixSupport],
        homePath: String?,
        fileSystem: (any ReadOnlyFileSystem)?
    ) -> [Finding] {
        var unitIndicesByFile: [Int: [Int]] = [:]
        for (idx, item) in units.enumerated() {
            unitIndicesByFile[item.fileIndex, default: []].append(idx)
        }

        var findings: [Finding] = []
        for (sourceIdx, sourceFile) in files.enumerated() where !sourceFile.units.isEmpty {
            guard !sourceFile.isCanonicalSharedAgentsFile else { continue }

            let supportsImportFix = sourceFile.agents.contains { agent in
                guard let support = fixSupports[agent] else { return false }
                return support.supportsAtImports && support.supportedKinds.contains(.replaceDuplicateRulesWithImport)
            }
            guard supportsImportFix else { continue }
            guard let sourceUnitIndices = unitIndicesByFile[sourceIdx], !sourceUnitIndices.isEmpty else {
                continue
            }

            // Find the highest-overlap shared `AGENTS.md` target in the same repository.
            var bestTarget: (targetIdx: Int, matchedSourceUnits: [Int], allExact: Bool)?
            for (targetIdx, targetFile) in files.enumerated()
            where targetIdx != sourceIdx
                && targetFile.isCanonicalSharedAgentsFile
                && sourceFile.repoRoot != nil
                && sourceFile.repoRoot == targetFile.repoRoot
            {
                if Self.alreadyImportsTarget(
                    sourceFile: sourceFile,
                    targetFile: targetFile,
                    homePath: homePath,
                    fileSystem: fileSystem
                ) {
                    continue
                }

                guard let targetUnitIndices = unitIndicesByFile[targetIdx], !targetUnitIndices.isEmpty else {
                    continue
                }

                let targetNorms = Set(targetUnitIndices.map { units[$0].unit.normalizedText })
                var matchedSource: [Int] = []
                var allExact = true

                for sUnitIdx in sourceUnitIndices {
                    let sNorm = units[sUnitIdx].unit.normalizedText
                    if targetNorms.contains(sNorm) {
                        matchedSource.append(sUnitIdx)
                    } else if targetUnitIndices.contains(where: { nearDupUnitPairs[UnitPair(sUnitIdx, $0)] != nil }) {
                        matchedSource.append(sUnitIdx)
                        allExact = false
                    }
                }

                let overlap = Double(matchedSource.count) / Double(sourceUnitIndices.count)
                guard overlap >= config.blockImportOverlapThreshold else { continue }

                if let current = bestTarget {
                    if matchedSource.count > current.matchedSourceUnits.count {
                        bestTarget = (targetIdx, matchedSource, allExact)
                    }
                } else {
                    bestTarget = (targetIdx, matchedSource, allExact)
                }
            }

            guard let match = bestTarget else { continue }
            let targetFile = files[match.targetIdx]
            let minLine = match.matchedSourceUnits.map { units[$0].unit.lineRange.lowerBound }.min() ?? 1
            let maxLine = match.matchedSourceUnits.map { units[$0].unit.lineRange.upperBound }.max() ?? minLine

            let sourceSpan = SourceLocation(
                path: sourceFile.path,
                realPath: sourceFile.realPath,
                lineRange: minLine...maxLine
            )
            let targetSpan = SourceLocation(
                path: targetFile.path,
                realPath: targetFile.realPath
            )

            let importToken = Self.relativeImportToken(from: sourceFile.path, to: targetFile.path)
            let pct = Int((Double(match.matchedSourceUnits.count) / Double(sourceUnitIndices.count) * 100.0).rounded())
            let sourceName = URL(fileURLWithPath: sourceFile.path).lastPathComponent
            let targetName = URL(fileURLWithPath: targetFile.path).lastPathComponent
            let artifactIDs = Array(Set(sourceFile.artifactIDs + targetFile.artifactIDs)).sorted {
                $0.rawValue < $1.rawValue
            }
            let findingKind: Finding.Kind = match.allExact ? .exactDuplicate : .nearDuplicate
            let findingID = Self.hashFindingID(
                "blockImport|\(sourceFile.identityPath)|\(targetFile.identityPath)"
            )

            findings.append(
                Finding(
                    id: findingID,
                    kind: findingKind,
                    severity: .warning,
                    artifacts: artifactIDs,
                    spans: [sourceSpan, targetSpan],
                    message:
                        "\(pct)% (\(match.matchedSourceUnits.count)/\(sourceUnitIndices.count)) of rules in '\(sourceName)' duplicate '\(targetName)'; replace duplicated block with '\(importToken)'.",
                    suggestedFixes: [.replaceDuplicateRulesWithImport]
                )
            )
        }

        return findings
    }

    // MARK: - Step 6: Size Limits, Broken Imports & Invalid Configs

    private func detectDiagnosticAndLimitFindings(
        artifacts: [Artifact],
        resolutions: [Resolution],
        physicalRuleFiles: [PhysicalRuleFile],
        homePrefixes: [String],
        tokenizer: (any TokenCountingProvider)?
    ) -> [Finding] {
        struct DiagnosticAccumulator {
            var kind: Finding.Kind
            var severity: Severity
            var code: String
            var message: String
            var location: SourceLocation
            var identityLocationKey: String
            var artifactIDs: Set<ArtifactID>
        }

        var accumulators: [String: DiagnosticAccumulator] = [:]
        var artifactsByPath: [String: [ArtifactID]] = [:]
        var artifactsByID: [ArtifactID: Artifact] = [:]
        for artifact in artifacts {
            artifactsByPath[artifact.location.path, default: []].append(artifact.id)
            artifactsByPath[artifact.location.realPath, default: []].append(artifact.id)
            artifactsByID[artifact.id] = artifact
        }

        func recordDiagnostic(
            _ diag: Diagnostic,
            fallbackLocation: SourceLocation?,
            owningArtifact: ArtifactID?,
            fallbackArtifacts: [ArtifactID] = []
        ) {
            guard let mapped = Self.classifyDiagnostic(diag) else { return }
            let loc = diag.location ?? fallbackLocation ?? SourceLocation(path: "<unknown>", realPath: "<unknown>")
            let idPath = Self.makeIdentityPath(loc.path, homePrefixes: homePrefixes)
            let rangeKey = loc.lineRange.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "0"
            let keyPathKey = loc.keyPath?.joined(separator: ".") ?? ""
            let locKey = "\(idPath):\(rangeKey):\(keyPathKey)"
            let dedupeKey = "\(diag.code)|\(locKey)"

            var relatedIDs: Set<ArtifactID> = []
            if let owningArtifact {
                relatedIDs.insert(owningArtifact)
            } else if let byPath = artifactsByPath[loc.path] {
                relatedIDs.formUnion(byPath)
            } else if let byReal = artifactsByPath[loc.realPath] {
                relatedIDs.formUnion(byReal)
            } else if !fallbackArtifacts.isEmpty {
                relatedIDs.formUnion(fallbackArtifacts)
            }

            if var existing = accumulators[dedupeKey] {
                existing.artifactIDs.formUnion(relatedIDs)
                if Self.severityRank(mapped.severity) > Self.severityRank(existing.severity) {
                    existing.severity = mapped.severity
                }
                accumulators[dedupeKey] = existing
            } else {
                accumulators[dedupeKey] = DiagnosticAccumulator(
                    kind: mapped.kind,
                    severity: mapped.severity,
                    code: diag.code,
                    message: diag.message,
                    location: loc,
                    identityLocationKey: locKey,
                    artifactIDs: relatedIDs
                )
            }
        }

        for artifact in artifacts {
            for diag in artifact.diagnostics {
                recordDiagnostic(diag, fallbackLocation: artifact.location, owningArtifact: artifact.id)
            }
        }

        for resolution in resolutions {
            let orderedIDs = resolution.ordered.map(\.artifactID)
            let resRuleArtifacts = orderedIDs.filter { artifactsByID[$0]?.kind == .rules }
            let fallbackIDs = resRuleArtifacts.isEmpty ? orderedIDs : resRuleArtifacts
            for warning in resolution.warnings {
                recordDiagnostic(
                    warning,
                    fallbackLocation: nil,
                    owningArtifact: nil,
                    fallbackArtifacts: fallbackIDs
                )
            }
        }

        var findings: [Finding] = []
        for key in accumulators.keys.sorted() {
            guard let item = accumulators[key] else { continue }
            let findingID = Self.hashFindingID("diag|\(item.kind.rawValue)|\(item.code)|\(item.identityLocationKey)")
            let spans = item.location.path == "<unknown>" ? [] : [item.location]
            findings.append(
                Finding(
                    id: findingID,
                    kind: item.kind,
                    severity: item.severity,
                    artifacts: item.artifactIDs.sorted { $0.rawValue < $1.rawValue },
                    spans: spans,
                    message: item.message
                )
            )
        }

        // Configurable large always-on rule file token threshold (`PLAN.md` §6.5).
        if let maxTokens = config.maxAlwaysOnRuleTokens, let tokenizer {
            for file in physicalRuleFiles where file.hasAlwaysOnArtifact {
                let representativeAgent = file.agents.sorted().first ?? .claudeCode
                let estimate = tokenizer.estimateTokens(
                    text: file.rawContentForTokens,
                    contentHash: file.contentHash,
                    agent: representativeAgent,
                    model: nil
                )
                if estimate.tokens > maxTokens {
                    let findingID = Self.hashFindingID("sizeLimitTokens|\(file.identityPath)|\(maxTokens)")
                    let fileName = URL(fileURLWithPath: file.path).lastPathComponent
                    findings.append(
                        Finding(
                            id: findingID,
                            kind: .sizeLimit,
                            severity: .warning,
                            artifacts: file.artifactIDs,
                            spans: [SourceLocation(path: file.path, realPath: file.realPath)],
                            message:
                                "Always-on rules file '\(fileName)' is \(estimate.tokens) tokens, exceeding configured \(maxTokens)-token threshold."
                        )
                    )
                }
            }
        }

        return findings
    }

    private static func classifyDiagnostic(_ diagnostic: Diagnostic) -> (kind: Finding.Kind, severity: Severity)? {
        let code = diagnostic.code
        switch code {
        case "mcp.unapproved", "codex.projectUntrusted":
            return nil

        case "rules.sizeLimitExceeded", "rules.truncated", "import.maxDepthExceeded":
            return (.sizeLimit, .warning)

        case "import.broken", "import.cycle", "import.invalidUTF8":
            return (.brokenImport, .error)

        default:
            if code.hasPrefix("json.")
                || code.hasPrefix("toml.")
                || code.hasSuffix(".readFailed")
                || code.hasSuffix(".invalidUTF8")
            {
                return (.invalidConfig, .error)
            }
            if code.hasPrefix("frontmatter.")
                || code.hasPrefix("mcp.")
                || code.hasPrefix("command.")
                || code.hasPrefix("rules.")
                || code.hasPrefix("skill.")
                || code.hasPrefix("subagent.")
                || code.hasPrefix("settings.")
            {
                return (.invalidConfig, diagnostic.severity)
            }
            return nil
        }
    }

    // MARK: - Graph, Path & Sorting Helpers

    private func connectedComponents<T: Hashable>(
        items: [T],
        connected: (T, T) -> Bool
    ) -> [[T]] {
        guard items.count >= 2 else { return items.map { [$0] } }
        var visited: Set<Int> = []
        var components: [[T]] = []

        for start in 0..<items.count where !visited.contains(start) {
            var queue: [Int] = [start]
            visited.insert(start)
            var cursor = 0
            var component: [T] = []

            while cursor < queue.count {
                let current = queue[cursor]
                cursor += 1
                component.append(items[current])

                for candidate in 0..<items.count where !visited.contains(candidate) {
                    if connected(items[current], items[candidate]) {
                        visited.insert(candidate)
                        queue.append(candidate)
                    }
                }
            }

            components.append(component)
        }

        return components
    }

    private static func computeHomePrefixes(
        homePath: String?,
        fileSystem: (any ReadOnlyFileSystem)?
    ) -> [String] {
        guard let homePath, !homePath.isEmpty else { return [] }
        let stdURL = URL(fileURLWithPath: homePath).standardizedFileURL
        var candidates: Set<String> = [stdURL.path]
        if let fileSystem {
            candidates.insert(fileSystem.resolveSymlinks(stdURL).standardizedFileURL.path)
        } else {
            candidates.insert(stdURL.resolvingSymlinksInPath().standardizedFileURL.path)
        }
        return candidates.filter { !$0.isEmpty && $0 != "/" }.sorted { $0.count > $1.count }
    }

    private static func makeIdentityPath(_ rawPath: String, homePrefixes: [String]) -> String {
        let std = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        for prefix in homePrefixes {
            if std == prefix {
                return "~"
            }
            if std.hasPrefix(prefix + "/") {
                return "~" + String(std.dropFirst(prefix.count))
            }
        }
        return std
    }

    private static func inferRepoRoot(
        for artifacts: [Artifact],
        path: String,
        realPath: String,
        repos: [DiscoveredRepo]
    ) -> String? {
        let isGlobalOnly = artifacts.allSatisfy { $0.scope == .user || $0.scope == .managed }
        if isGlobalOnly {
            return nil
        }

        let sortedRepos = repos.sorted { $0.path.count > $1.path.count }
        for repo in sortedRepos {
            if path == repo.path || path.hasPrefix(repo.path + "/")
                || realPath == repo.realPath || realPath.hasPrefix(repo.realPath + "/")
            {
                return repo.path
            }
        }

        // Fallback when `repos` wasn't passed explicitly: infer repository folder above known agent subpaths.
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let components = url.pathComponents
        for (idx, comp) in components.enumerated() where idx > 1 && privateAgentDirectories.contains(comp) {
            let prefixComponents = Array(components[0..<idx])
            return NSString.path(withComponents: prefixComponents)
        }
        return url.deletingLastPathComponent().path
    }

    private static func alreadyImportsTarget(
        sourceFile: PhysicalRuleFile,
        targetFile: PhysicalRuleFile,
        homePath: String?,
        fileSystem: (any ReadOnlyFileSystem)?
    ) -> Bool {
        guard !sourceFile.directImports.isEmpty else { return false }
        let sourceDir = URL(fileURLWithPath: sourceFile.path).deletingLastPathComponent().standardizedFileURL
        let homeURL = homePath.map { URL(fileURLWithPath: $0).standardizedFileURL }

        for imported in sourceFile.directImports {
            let resolvedURL: URL
            if imported.hasPrefix("~/"), let homeURL {
                resolvedURL = homeURL.appendingPathComponent(String(imported.dropFirst(2))).standardizedFileURL
            } else if imported.hasPrefix("/") {
                resolvedURL = URL(fileURLWithPath: imported).standardizedFileURL
            } else {
                resolvedURL = sourceDir.appendingPathComponent(imported).standardizedFileURL
            }

            let resolvedReal =
                fileSystem?.resolveSymlinks(resolvedURL).standardizedFileURL.path
                ?? resolvedURL.resolvingSymlinksInPath().standardizedFileURL.path
            if resolvedURL.path == targetFile.path || resolvedReal == targetFile.realPath {
                return true
            }
        }
        return false
    }

    private static func relativeImportToken(from sourceFilePath: String, to targetFilePath: String) -> String {
        let sourceDirComponents = URL(fileURLWithPath: sourceFilePath)
            .standardizedFileURL
            .deletingLastPathComponent()
            .pathComponents
        let targetComponents = URL(fileURLWithPath: targetFilePath)
            .standardizedFileURL
            .pathComponents

        var common = 0
        while common < sourceDirComponents.count
            && common < targetComponents.count
            && sourceDirComponents[common] == targetComponents[common]
        {
            common += 1
        }

        let upMoves = Array(repeating: "..", count: sourceDirComponents.count - common)
        let downMoves = Array(targetComponents[common...])
        let rel = (upMoves + downMoves).joined(separator: "/")
        return "@\(rel)"
    }

    private static func singleLinePreview(_ raw: String, maxCharacters: Int = 110) -> String {
        var collapsed =
            raw
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        for prefix in ["- ", "* ", "+ "] where collapsed.hasPrefix(prefix) {
            collapsed = String(collapsed.dropFirst(prefix.count))
            break
        }
        if collapsed.count <= maxCharacters {
            return collapsed
        }
        let endIdx = collapsed.index(collapsed.startIndex, offsetBy: maxCharacters - 1)
        return String(collapsed[..<endIdx]) + "…"
    }

    private static func hashFindingID(_ seed: String) -> String {
        ContentHasher.sha256Hex(Data(seed.utf8))
    }

    private static func severityRank(_ severity: Severity) -> Int {
        switch severity {
        case .info:
            return 0
        case .warning:
            return 1
        case .error:
            return 2
        }
    }

    private static func deduplicateAndSort(_ findings: [Finding]) -> [Finding] {
        var byID: [String: Finding] = [:]
        for finding in findings where byID[finding.id] == nil {
            byID[finding.id] = finding
        }
        return byID.values.sorted { lhs, rhs in
            let leftSev = severityRank(lhs.severity)
            let rightSev = severityRank(rhs.severity)
            if leftSev != rightSev {
                return leftSev > rightSev
            }
            if lhs.kind.rawValue != rhs.kind.rawValue {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            return lhs.id < rhs.id
        }
    }
}
