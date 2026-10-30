/// Parsed configuration for a lifecycle hook entry.
public struct HookConfig: Sendable, Codable, Hashable {
    /// Hook lifecycle event name (e.g. `PreToolUse`, `PostToolUse`, `SessionStart`).
    public var event: String
    /// Optional tool or pattern matcher restricting when the hook runs.
    public var matcher: String?
    /// Shell command executed by the hook.
    public var command: String
    /// Optional execution timeout in seconds.
    public var timeoutSeconds: Int?

    /// Creates a hook configuration payload.
    public init(
        event: String,
        matcher: String? = nil,
        command: String,
        timeoutSeconds: Int? = nil
    ) {
        self.event = event
        self.matcher = matcher
        self.command = command
        self.timeoutSeconds = timeoutSeconds
    }
}
