import BentoCore

/// Typed errors emitted by `BentoScanner` discovery, resolution, and watcher operations.
public enum BentoScannerError: Error, Sendable, Equatable {
    case notImplemented
    case unknownAgent(AgentID)
    case resolutionUnsupported(AgentID)
}
