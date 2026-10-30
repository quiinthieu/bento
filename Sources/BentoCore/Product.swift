/// Single source of truth for product display name, bundle identifier, CLI executable name,
/// and Application Support directory name. Keep synchronized with `Config/Product.xcconfig`.
public enum Product: Sendable {
    /// Human-facing application display name.
    public static let name = "Bento"

    /// Reverse-DNS macOS application bundle identifier.
    public static let bundleID = "com.quiinthieu.bento"

    /// Companion command-line executable name.
    public static let cliName = "bentoctx"

    /// Folder name under `~/Library/Application Support/`.
    public static let supportDirName = "Bento"

    /// Marketing version string.
    public static let version = "0.1.0"

    /// Builds the CLI `--help` abstract from the active product display name.
    public static func cliHelpAbstract(productName: String = Product.name) -> String {
        "\(productName) companion CLI for auditing AI coding agent context budgets and rules hygiene."
    }
}
