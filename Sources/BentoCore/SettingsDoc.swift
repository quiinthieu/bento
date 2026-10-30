/// Redacted settings tree parsed from an agent JSON, JSONC, or TOML configuration file.
public struct SettingsDoc: Sendable, Codable, Hashable {
    /// Underlying serialization syntax of the settings file.
    public enum Format: String, Sendable, Codable, CaseIterable {
        case json
        case toml
    }

    /// Source file format.
    public var format: Format
    /// Top-level redacted key/value tree (`«redacted»` substituted for secret values).
    public var tree: [String: JSONValue]

    /// Creates a redacted settings document payload.
    public init(format: Format, tree: [String: JSONValue]) {
        self.format = format
        self.tree = tree
    }
}
