import BentoCore
import Foundation
import GRDB

extension BentoStore: MCPProbeCaching, MCPConsentPersisting {
    private static let mcpConsentSettingKey = "mcp_probe_consented_hashes"

    // MARK: - MCPProbeCaching

    public func saveMCPProbe(_ record: MCPProbeRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let toolsData = try encoder.encode(record.tools)
        let toolsJSON = String(decoding: toolsData, as: UTF8.self)

        try dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO mcp_probe (
                        server_config_hash, agent, server_name, probed_at,
                        ok, error, tools_json, tools_tokens_estimate, protocol_version
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    record.serverConfigHash,
                    record.agent.rawValue,
                    record.serverName,
                    record.probedAt.timeIntervalSince1970,
                    record.ok,
                    record.error,
                    toolsJSON,
                    record.toolsTokensEstimate,
                    record.protocolVersion
                ]
            )
        }
    }

    public func cachedMCPProbe(forHash serverConfigHash: String) throws -> MCPProbeRecord? {
        try dbWriter.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM mcp_probe WHERE server_config_hash = ?",
                    arguments: [serverConfigHash]
                )
            else {
                return nil
            }
            return try Self.decodeMCPProbeRow(row)
        }
    }

    public func allMCPProbes() throws -> [MCPProbeRecord] {
        try dbWriter.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM mcp_probe ORDER BY probed_at DESC, server_config_hash ASC"
            )
            return try rows.map(Self.decodeMCPProbeRow)
        }
    }

    public func mcpFallbackEstimate() throws -> MCPFallbackEstimate? {
        let records = try allMCPProbes().filter { $0.ok && !$0.tools.isEmpty && $0.toolsTokensEstimate > 0 }
        guard !records.isEmpty else {
            return nil
        }

        let perToolCounts = records.map { record in
            max(1, Int((Double(record.toolsTokensEstimate) / Double(record.tools.count)).rounded()))
        }.sorted()

        let toolCounts = records.map { $0.tools.count }.sorted()

        return MCPFallbackEstimate(
            medianTokensPerTool: Self.medianInt(ofSorted: perToolCounts),
            medianToolsPerServer: Self.medianInt(ofSorted: toolCounts),
            sampleServerCount: records.count
        )
    }

    // MARK: - MCPConsentPersisting

    public func consentedMCPConfigHashes() throws -> Set<String> {
        let stored = try setting([String].self, forKey: Self.mcpConsentSettingKey) ?? []
        return Set(stored)
    }

    public func saveConsentedMCPConfigHashes(_ hashes: Set<String>) throws {
        try setSetting(hashes.sorted(), forKey: Self.mcpConsentSettingKey)
    }

    // MARK: - Helpers

    private static func decodeMCPProbeRow(_ row: Row) throws -> MCPProbeRecord {
        let hash: String = row["server_config_hash"]
        let rawAgent: String = row["agent"]
        guard let agent = AgentID(rawValue: rawAgent) else {
            throw BentoStoreError.corruptedPayload(table: "mcp_probe", column: "agent", id: hash)
        }

        let toolsRaw: String = row["tools_json"]
        guard let toolsData = toolsRaw.data(using: .utf8),
            let tools = try? JSONDecoder().decode([MCPToolSchema].self, from: toolsData)
        else {
            throw BentoStoreError.corruptedPayload(table: "mcp_probe", column: "tools_json", id: hash)
        }

        return MCPProbeRecord(
            serverConfigHash: hash,
            agent: agent,
            serverName: row["server_name"],
            probedAt: Date(timeIntervalSince1970: row["probed_at"]),
            ok: row["ok"],
            error: row["error"],
            tools: tools,
            toolsTokensEstimate: row["tools_tokens_estimate"],
            protocolVersion: row["protocol_version"]
        )
    }

    private static func medianInt(ofSorted sorted: [Int]) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return Int((Double(sorted[mid - 1] + sorted[mid]) / 2.0).rounded())
    }
}
