import BentoCore
import Foundation
import Testing

struct CoreModelsCodableTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_730_000_000)

    @Test("AgentID, Scope, ArtifactKind, Confidence, BudgetCategory, Severity, and FixKind round-trip")
    func enumsRoundTripAndCompare() throws {
        for agent in AgentID.allCases {
            #expect(try roundTrip(agent) == agent)
        }
        #expect(AgentID.allCases.count == 6)

        let orderedScopes: [Scope] = [.managed, .projectLocal, .project, .directory, .user, .builtIn]
        #expect(orderedScopes.sorted() == orderedScopes)
        for scope in Scope.allCases {
            #expect(try roundTrip(scope) == scope)
        }

        for kind in ArtifactKind.allCases {
            #expect(try roundTrip(kind) == kind)
        }
        #expect(ArtifactKind.allCases.count == 10)

        for confidence in [Confidence.exact, .estimated, .measured] {
            #expect(try roundTrip(confidence) == confidence)
        }

        for category in BudgetCategory.allCases {
            #expect(try roundTrip(category) == category)
        }

        let orderedSeverities: [Severity] = [.info, .warning, .error]
        #expect(orderedSeverities.sorted() == orderedSeverities)
        for severity in Severity.allCases {
            #expect(try roundTrip(severity) == severity)
        }

        for fixKind in FixKind.allCases {
            #expect(try roundTrip(fixKind) == fixKind)
        }
    }

    @Test("LoadMode, SourceLocation, Diagnostic, and JSONValue round-trip")
    func primitivesAndJSONValueRoundTrip() throws {
        let modes: [LoadMode] = [
            .always,
            .frontmatterOnly,
            .deferred,
            .onInvoke,
            .conditional(globs: ["**/*.swift", "Sources/**"]),
            .never
        ]
        for mode in modes {
            #expect(try roundTrip(mode) == mode)
        }

        let location = SourceLocation(
            path: "/fixture/home/.claude/settings.json",
            realPath: "/fixture/real/.claude/settings.json",
            keyPath: ["mcpServers", "github"],
            lineRange: 10...24
        )
        #expect(try roundTrip(location) == location)

        let bareLocation = SourceLocation(path: "/a", realPath: "/a")
        #expect(try roundTrip(bareLocation) == bareLocation)

        let diagnostic = Diagnostic(
            code: "PARSE_001",
            severity: .warning,
            message: "Trailing comma tolerated in JSONC",
            location: location
        )
        #expect(try roundTrip(diagnostic) == diagnostic)

        let jsonTree: JSONValue = .object([
            "nullVal": .null,
            "flag": .bool(true),
            "count": .int(42),
            "ratio": .double(1.25),
            "text": .string("hello"),
            "items": .array([.int(1), .string("two"), .bool(false)])
        ])
        #expect(try roundTrip(jsonTree) == jsonTree)
    }

    @Test("Every ArtifactPayload variant and Artifact round-trip cleanly")
    func artifactAndAllPayloadsRoundTrip() throws {
        let payloads: [ArtifactPayload] = [
            .rules(
                RulesDoc(
                    content: "# Rules\n- Test first",
                    imports: ["AGENTS.md"],
                    frontmatter: ["alwaysApply": .bool(true)],
                    byteCount: 20,
                    characterCount: 20,
                    wasTruncated: false
                )
            ),
            .skill(
                SkillDoc(
                    name: "review",
                    description: "Review pull requests",
                    frontmatter: ["name": .string("review")],
                    body: "Check tests and types.",
                    supportingFiles: ["scripts/check.sh"]
                )
            ),
            .mcpServer(
                MCPServerConfig(
                    transport: .stdio(command: "npx", args: ["-y", "@modelcontextprotocol/server-github"]),
                    envKeys: ["GITHUB_TOKEN"],
                    disabled: false,
                    allowedTools: ["get_issue"],
                    disabledTools: ["delete_repo"]
                )
            ),
            .mcpServer(
                MCPServerConfig(
                    transport: .http(url: "https://mcp.example.com/v1"),
                    envKeys: [],
                    disabled: true
                )
            ),
            .mcpServer(
                MCPServerConfig(
                    transport: .sse(url: "https://mcp.example.com/sse"),
                    envKeys: ["API_KEY"],
                    disabled: false
                )
            ),
            .subagent(
                SubagentDoc(
                    name: "researcher",
                    description: "Read-only codebase exploration",
                    model: "claude-sonnet-4-5",
                    tools: ["Read", "Grep"],
                    frontmatter: ["name": .string("researcher")],
                    body: "Explore without editing."
                )
            ),
            .command(
                CommandDoc(
                    name: "commit",
                    description: "Create conventional commit",
                    argumentHint: "<scope>",
                    body: "Inspect git diff first."
                )
            ),
            .hook(
                HookConfig(
                    event: "PreToolUse",
                    matcher: "Bash",
                    command: "/usr/local/bin/check-cmd",
                    timeoutSeconds: 10
                )
            ),
            .settings(
                SettingsDoc(
                    format: .json,
                    tree: ["model": .string("opus"), "apiKey": .string("«redacted»")]
                )
            ),
            .plugin(
                PluginManifest(
                    name: "acme-tools",
                    version: "1.2.0",
                    description: "Acme internal skills",
                    skills: ["deploy"],
                    agents: ["reviewer"],
                    commands: ["ship"],
                    mcpServers: ["acme"]
                )
            ),
            .other
        ]

        for (index, payload) in payloads.enumerated() {
            let location = SourceLocation(
                path: "/fixture/item-\(index)",
                realPath: "/fixture/item-\(index)",
                keyPath: ["items", "\(index)"],
                lineRange: 1...5
            )
            let artifact = Artifact(
                id: ArtifactID(
                    agent: .claudeCode,
                    kind: .rules,
                    scope: .project,
                    path: location.path,
                    keyPath: location.keyPath
                ),
                agent: .claudeCode,
                kind: .rules,
                scope: .project,
                name: "item-\(index)",
                location: location,
                contentHash: ContentHasher.sha256NormalizedText("sample-\(index)"),
                enabled: true,
                loadMode: .always,
                payload: payload,
                diagnostics: []
            )
            #expect(try roundTrip(artifact) == artifact)
        }
    }

    @Test("Resolution, Budget, UsageEvent, and Finding round-trip cleanly")
    func resolutionBudgetUsageAndFindingRoundTrip() throws {
        let winID = ArtifactID(
            agent: .claudeCode, kind: .mcpServer, scope: .projectLocal, path: "/repo/.mcp.json", keyPath: ["github"])
        let loseID = ArtifactID(
            agent: .claudeCode, kind: .mcpServer, scope: .user, path: "/home/.claude.json", keyPath: ["github"])

        let resolution = Resolution(
            agent: .claudeCode,
            folder: "/repo",
            ordered: [
                ResolvedArtifact(
                    artifactID: winID,
                    effectiveLoadMode: .always,
                    reason: "projectLocal overrides user"
                )
            ],
            shadowed: [
                ShadowRecord(
                    shadowedArtifactID: loseID,
                    winningArtifactID: winID,
                    reason: "Overridden by projectLocal server 'github'"
                )
            ],
            warnings: []
        )
        #expect(try roundTrip(resolution) == resolution)

        let budget = Budget(
            agent: .codex,
            folder: "/repo",
            model: "gpt-5-codex",
            items: [
                BudgetItem(
                    artifactID: nil,
                    category: .builtInSystem,
                    label: "Built-in system prompt",
                    tokens: 3_200,
                    range: 2_900...3_500,
                    confidence: .estimated,
                    method: "builtin baseline",
                    countsTowardPrePrompt: true
                ),
                BudgetItem(
                    artifactID: winID,
                    category: .rules,
                    label: "AGENTS.md",
                    tokens: 412,
                    range: nil,
                    confidence: .exact,
                    method: "o200k_base",
                    countsTowardPrePrompt: true
                )
            ],
            measuredFirstTurnInput: 3_650,
            contextWindow: 200_000
        )
        #expect(try roundTrip(budget) == budget)

        let eventKinds: [UsageEvent.Kind] = [
            .sessionStart(model: "claude-opus-4-6"),
            .sessionStart(model: nil),
            .tokenUsage(input: 4_100, cachedInput: 3_000, output: 520, turnIndex: 0),
            .skillInvoked(name: "review"),
            .mcpToolCalled(server: "github", tool: "list_pull_requests"),
            .subagentInvoked(name: "researcher"),
            .commandInvoked(name: "commit"),
            .builtinToolCalled(name: "Read")
        ]
        for kind in eventKinds {
            let event = UsageEvent(
                agent: .claudeCode,
                sessionID: "sess-01",
                timestamp: Self.fixedDate,
                cwd: "/repo",
                kind: kind
            )
            #expect(try roundTrip(event) == event)
        }

        for findingKind in Finding.Kind.allCases {
            let finding = Finding(
                id: "finding-\(findingKind.rawValue)",
                kind: findingKind,
                severity: .warning,
                artifacts: [winID, loseID],
                spans: [SourceLocation(path: "/repo/CLAUDE.md", realPath: "/repo/CLAUDE.md", lineRange: 3...8)],
                message: "Sample finding for \(findingKind.rawValue)",
                suggestedFixes: [.replaceDuplicateRulesWithImport]
            )
            #expect(try roundTrip(finding) == finding)
        }
    }

    @Test("ScanScope, Snapshot, and SnapshotDelta round-trip deterministically")
    func snapshotAndDeltaRoundTrip() throws {
        let globalScope = ScanScope(agent: .claudeCode, repoPath: nil)
        let repoScope = ScanScope(agent: .claudeCode, repoPath: "/home/repos/demo-app")
        #expect(globalScope < repoScope)
        #expect(try roundTrip(globalScope) == globalScope)
        #expect(try roundTrip(repoScope) == repoScope)

        let artifactID = ArtifactID(
            agent: .claudeCode,
            kind: .rules,
            scope: .project,
            path: "<HOME>/repos/demo-app/CLAUDE.md"
        )
        let artifact = Artifact(
            id: artifactID,
            agent: .claudeCode,
            kind: .rules,
            scope: .project,
            name: "CLAUDE.md",
            location: SourceLocation(
                path: "/home/repos/demo-app/CLAUDE.md",
                realPath: "/home/repos/demo-app/CLAUDE.md",
                lineRange: 1...5
            ),
            contentHash: ContentHasher.sha256NormalizedText("# Rules"),
            enabled: true,
            loadMode: .always,
            payload: .rules(RulesDoc(content: "# Rules", byteCount: 7, characterCount: 7))
        )
        let repo = DiscoveredRepo(
            path: "/home/repos/demo-app",
            realPath: "/home/repos/demo-app",
            displayName: "demo-app",
            sources: [.claudeLogs],
            isPinned: true
        )
        let resolution = Resolution(
            agent: .claudeCode,
            folder: "/home/repos/demo-app",
            ordered: [
                ResolvedArtifact(
                    artifactID: artifactID,
                    effectiveLoadMode: .always,
                    reason: "project CLAUDE.md"
                )
            ]
        )
        let snapshot = Snapshot(
            id: "snap-001",
            createdAt: Self.fixedDate,
            homePath: "/home",
            scannerVersion: "0.1.0",
            detections: [
                .claudeCode: DetectionResult(isDetected: true, detectedPaths: ["/home/.claude"])
            ],
            repos: [repo],
            scopedArtifacts: [
                globalScope: [],
                repoScope: [artifact]
            ],
            resolutions: [resolution]
        )

        let decodedSnapshot = try roundTrip(snapshot)
        #expect(decodedSnapshot == snapshot)
        #expect(decodedSnapshot.artifacts == [artifact])
        #expect(decodedSnapshot.artifacts(agent: .claudeCode, repoPath: "/home/repos/demo-app") == [artifact])
        #expect(decodedSnapshot.resolution(for: .claudeCode, repoPath: "/home/repos/demo-app") == resolution)

        let delta = SnapshotDelta(
            snapshot: snapshot,
            reason: .incrementalRescan,
            rescannedScopes: [repoScope],
            changedPaths: ["/home/repos/demo-app/CLAUDE.md"],
            changedLogAgents: [.claudeCode]
        )
        #expect(try roundTrip(delta) == delta)
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
}
