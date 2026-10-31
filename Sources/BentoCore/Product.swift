/// Single source of truth for product display name, bundle identifier, CLI executable name,
/// Application Support directory name, marketing version, and build number.
/// Keep synchronized with `Config/Product.xcconfig` via `Scripts/bump-version.sh`.
public enum Product: Sendable {
    /// Human-facing application display name.
    public static let name = "Bento"

    /// Reverse-DNS macOS application bundle identifier.
    public static let bundleID = "com.quiinthieu.bento"

    /// Companion command-line executable name.
    public static let cliName = "bentoctx"

    /// Folder name under `~/Library/Application Support/`.
    public static let supportDirName = "Bento"

    /// Marketing version string (`CFBundleShortVersionString` / `MARKETING_VERSION`).
    public static let version = "0.1.0"

    /// Monotonic build number string (`CFBundleVersion` / `CURRENT_PROJECT_VERSION`).
    public static let buildNumber = "1"

    /// Builds the CLI `--help` abstract from the active product display name.
    public static func cliHelpAbstract(productName: String = Product.name) -> String {
        "\(productName) companion CLI for auditing AI coding agent context budgets and rules hygiene."
    }
}
