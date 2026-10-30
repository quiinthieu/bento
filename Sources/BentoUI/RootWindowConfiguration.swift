import BentoCore

/// Configuration for the primary application window.
public struct RootWindowConfiguration: Sendable, Equatable {
    /// Display name shown in the macOS window title bar.
    public var windowTitle: String

    /// Creates a root window configuration defaulting to `Product.name`.
    public init(productName: String = Product.name) {
        self.windowTitle = productName
    }
}
