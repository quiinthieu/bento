import AppKit
import BentoCore
import SwiftUI

/// Primary macOS window scene titled from `Product.name`.
public struct RootScene: Scene {
    private let configuration: RootWindowConfiguration

    /// Creates the primary scene using the given window configuration.
    public init(configuration: RootWindowConfiguration = RootWindowConfiguration()) {
        self.configuration = configuration
    }

    public var body: some Scene {
        WindowGroup(configuration.windowTitle) {
            RootView(configuration: configuration)
                .task {
                    if CommandLine.arguments.contains("--smoke-test-quit") {
                        NSApplication.shared.terminate(nil)
                    }
                }
        }
    }
}
