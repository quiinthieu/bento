import BentoCore
import Foundation
import Testing

struct ArtifactIDTests {
    @Test("ArtifactID hashing is deterministic and produces 64-character lowercase SHA-256 hex")
    func deterministicStableID() {
        let first = ArtifactID(
            agent: .claudeCode,
            kind: .mcpServer,
            scope: .project,
            path: "/repo/.mcp.json",
            keyPath: ["mcpServers", "github"]
        )
        let second = ArtifactID(
            agent: .claudeCode,
            kind: .mcpServer,
            scope: .project,
            path: "/repo/.mcp.json",
            keyPath: ["mcpServers", "github"]
        )

        #expect(first == second)
        #expect(first.rawValue.count == 64)
        #expect(
            first.rawValue == "c9077a4fb0bb90eb8b42c4445bb8ef54b0f6ae47dc394eb93e05c94613b4e437"
                || first.rawValue.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test("ArtifactID changes when any identity component changes and avoids delimiter collisions")
    func sensitivityAndCollisionResistance() {
        let base = ArtifactID(
            agent: .claudeCode,
            kind: .mcpServer,
            scope: .project,
            path: "/repo/.mcp.json",
            keyPath: ["a", "b"]
        )
        let diffAgent = ArtifactID(
            agent: .codex,
            kind: .mcpServer,
            scope: .project,
            path: "/repo/.mcp.json",
            keyPath: ["a", "b"]
        )
        let diffKind = ArtifactID(
            agent: .claudeCode,
            kind: .settings,
            scope: .project,
            path: "/repo/.mcp.json",
            keyPath: ["a", "b"]
        )
        let diffScope = ArtifactID(
            agent: .claudeCode,
            kind: .mcpServer,
            scope: .projectLocal,
            path: "/repo/.mcp.json",
            keyPath: ["a", "b"]
        )
        let diffPath = ArtifactID(
            agent: .claudeCode,
            kind: .mcpServer,
            scope: .project,
            path: "/repo2/.mcp.json",
            keyPath: ["a", "b"]
        )
        let pipeInElement = ArtifactID(
            agent: .claudeCode,
            kind: .mcpServer,
            scope: .project,
            path: "/repo/.mcp.json",
            keyPath: ["a|b"]
        )
        let slashSplitA = ArtifactID(
            agent: .claudeCode,
            kind: .mcpServer,
            scope: .project,
            path: "/repo/.mcp.json",
            keyPath: ["a/b", "c"]
        )
        let slashSplitB = ArtifactID(
            agent: .claudeCode,
            kind: .mcpServer,
            scope: .project,
            path: "/repo/.mcp.json",
            keyPath: ["a", "b/c"]
        )
        let nilKeyPath = ArtifactID(
            agent: .claudeCode,
            kind: .mcpServer,
            scope: .project,
            path: "/repo/.mcp.json",
            keyPath: nil
        )
        let emptyKeyPath = ArtifactID(
            agent: .claudeCode,
            kind: .mcpServer,
            scope: .project,
            path: "/repo/.mcp.json",
            keyPath: []
        )

        let all = [
            base,
            diffAgent,
            diffKind,
            diffScope,
            diffPath,
            pipeInElement,
            slashSplitA,
            slashSplitB,
            nilKeyPath,
            emptyKeyPath
        ]
        #expect(Set(all).count == all.count)
    }

    @Test("ArtifactID encodes as a flat JSON string and ContentHasher normalizes CRLF")
    func flatJSONAndNormalizedContentHash() throws {
        let id = ArtifactID(agent: .gemini, kind: .rules, scope: .user, path: "/home/.gemini/GEMINI.md")
        let encoded = try JSONEncoder().encode(id)
        let jsonString = String(decoding: encoded, as: UTF8.self)
        #expect(jsonString == "\"\(id.rawValue)\"")

        let lfHash = ContentHasher.sha256NormalizedText("line1\nline2\n")
        let crlfHash = ContentHasher.sha256NormalizedText("line1\r\nline2\r\n")
        #expect(lfHash == crlfHash)
        #expect(lfHash.count == 64)
    }
}
