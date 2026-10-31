/// Typed errors emitted by `BentoStore` SQLite persistence operations.
public enum BentoStoreError: Error, Sendable, Equatable {
    case notImplemented
    case invalidDatabaseDirectory(String)
    case corruptedPayload(table: String, column: String, id: String)
}
