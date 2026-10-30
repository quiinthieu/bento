import ArgumentParser
import BentoCore

/// Root command-line entry point configured dynamically from `Product`.
@main
struct BentoCLICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: Product.cliName,
        abstract: Product.cliHelpAbstract(),
        version: Product.version
    )

    mutating func run() async throws {
        print("\(Product.name) (\(Product.cliName)) \(Product.version)")
    }
}
