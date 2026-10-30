/// Declarative catalog of every configuration and log path inspected by an `AgentAdapter`,
/// paired with verification date and official documentation URL provenance.
public struct PathCatalog: Sendable, Codable, Hashable {
    /// A single documented path pattern in an adapter's catalog.
    public struct Entry: Sendable, Codable, Hashable {
        /// Stable entry identifier within the adapter.
        public var id: String
        /// Path pattern (using `~`, `<repo>`, `*`, `**` placeholders).
        public var pattern: String
        /// Scope tier associated with matches of this pattern.
        public var scope: Scope
        /// Primary artifact kind produced from this path.
        public var kind: ArtifactKind
        /// ISO-8601 date (`YYYY-MM-DD`) when this path was verified against official docs.
        public var verifiedAt: String?
        /// Official documentation URL confirming the path and precedence behaviour.
        public var docURL: String?

        /// Creates a path catalog entry.
        public init(
            id: String,
            pattern: String,
            scope: Scope,
            kind: ArtifactKind,
            verifiedAt: String? = nil,
            docURL: String? = nil
        ) {
            self.id = id
            self.pattern = pattern
            self.scope = scope
            self.kind = kind
            self.verifiedAt = verifiedAt
            self.docURL = docURL
        }
    }

    /// Ordered catalog entries declared by the adapter.
    public var entries: [Entry]

    /// Creates a path catalog.
    public init(entries: [Entry]) {
        self.entries = entries
    }
}
