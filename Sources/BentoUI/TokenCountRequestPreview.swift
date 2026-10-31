import BentoCore
import Foundation

/// Single artifact text payload inspected in the opt-in exact token-count API request preview (`PLAN.md` §6.3, §7).
public struct TokenCountPreviewItem: Sendable, Identifiable, Hashable {
    public var id: String
    public var artifactID: ArtifactID
    public var artifactName: String
    public var kind: ArtifactKind
    public var category: BudgetCategory
    public var label: String
    public var endpointURL: String
    public var httpMethod: String
    public var redactedHeaders: [String: String]
    public var httpBodyPreview: String
    public var rawText: String
    public var contentHash: String
    public var model: String?

    public init(
        id: String,
        artifactID: ArtifactID,
        artifactName: String,
        kind: ArtifactKind,
        category: BudgetCategory,
        label: String,
        endpointURL: String,
        httpMethod: String,
        redactedHeaders: [String: String],
        httpBodyPreview: String,
        rawText: String,
        contentHash: String,
        model: String?
    ) {
        self.id = id
        self.artifactID = artifactID
        self.artifactName = artifactName
        self.kind = kind
        self.category = category
        self.label = label
        self.endpointURL = endpointURL
        self.httpMethod = httpMethod
        self.redactedHeaders = redactedHeaders
        self.httpBodyPreview = httpBodyPreview
        self.rawText = rawText
        self.contentHash = contentHash
        self.model = model
    }

    /// Redacts sensitive credential headers (`x-api-key`, `x-goog-api-key`, `authorization`, etc.) to `"«redacted»"`.
    public static func redactHeaders(_ rawHeaders: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]
        let secretMarkers = ["key", "token", "secret", "password", "authorization", "cookie"]
        for (header, value) in rawHeaders {
            let lower = header.lowercased()
            if secretMarkers.contains(where: { lower.contains($0) }) {
                sanitized[header] = "«redacted»"
            } else {
                sanitized[header] = value
            }
        }
        return sanitized
    }
}

/// Complete opt-in request preview for Anthropic or Gemini token-count APIs before any network call is sent (`PLAN.md` §7).
public struct TokenCountRequestPreview: Sendable, Identifiable, Hashable {
    public var id: UUID
    public var provider: TokenCountAPIProviderID
    public var agent: AgentID
    public var repoPath: String
    public var items: [TokenCountPreviewItem]

    public init(
        id: UUID = UUID(),
        provider: TokenCountAPIProviderID,
        agent: AgentID,
        repoPath: String,
        items: [TokenCountPreviewItem]
    ) {
        self.id = id
        self.provider = provider
        self.agent = agent
        self.repoPath = repoPath
        self.items = items
    }
}
