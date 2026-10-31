import AppKit
import Foundation

/// Seam for Finder and external editor interactions so UI tests can verify external actions hermetically.
@MainActor
public protocol ExternalActionHandling {
    func revealInFinder(_ url: URL)
    func openInEditor(_ url: URL)
}

/// Default `NSWorkspace`-backed implementation for macOS Finder reveal and default editor launch.
@MainActor
public struct WorkspaceExternalActionHandler: ExternalActionHandling {
    public init() {}

    public func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url.standardizedFileURL])
    }

    public func openInEditor(_ url: URL) {
        NSWorkspace.shared.open(url.standardizedFileURL)
    }
}
