import BentoCore
import SwiftUI

/// Top-level view rendered inside the main application window.
public struct RootView: View {
    /// Configuration providing the window title and display metadata.
    public let configuration: RootWindowConfiguration

    /// Creates the root view with the provided window configuration.
    public init(configuration: RootWindowConfiguration = RootWindowConfiguration()) {
        self.configuration = configuration
    }

    public var body: some View {
        Color.clear
            .frame(minWidth: 720, minHeight: 480)
            .navigationTitle(configuration.windowTitle)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(configuration.windowTitle)
    }
}
