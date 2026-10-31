import ArgumentParser
import BentoCore

/// Root command-line entry point configured dynamically from `Product` (`PLAN.md` §6.8).
@main
struct BentoCLICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: Product.cliName,
        abstract: Product.cliHelpAbstract(),
        version: Product.version,
        subcommands: [
            ScanCommand.self,
            InventoryCommand.self,
            ResolveCommand.self,
            BudgetCommand.self
        ]
    )

    mutating func run() async throws {
        print("\(Product.name) (\(Product.cliName)) \(Product.version)")
    }
}
