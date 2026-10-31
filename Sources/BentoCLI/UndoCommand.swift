import ArgumentParser
import BentoCore
import BentoFixes
import BentoStore
import Foundation

/// Restores an applied fix from its backup manifest (`PLAN.md` §6.6, §6.8).
struct UndoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "undo",
        abstract: "Restore files modified by a previously applied fix from its backup."
    )

    @OptionGroup var common: CLICommonOptions

    @Argument(help: "Identifier of the applied fix from fix_journal.")
    var fixID: String

    @Flag(
        name: .long,
        help: "Restore from backup even if target files were manually edited after the fix was applied."
    )
    var force = false

    mutating func run() async throws {
        let (env, store, supportDir) = try common.makeRuntime(requirePersistentStore: true)
        defer { try? store.close() }

        let trashHandler: any TrashHandling =
            (common.home != nil)
            ? HermeticTrashHandler(trashDirectory: supportDir.appendingPathComponent("Trash", isDirectory: true))
            : SystemTrashHandler()

        let engine = FixEngine(
            homeURL: env.home,
            supportDirectory: supportDir,
            store: store,
            fileSystem: env.fileSystem,
            trashHandler: trashHandler,
            now: env.now
        )

        let result = try await engine.undo(
            fixID: fixID,
            allowChanges: true,
            force: force
        )

        if common.json {
            let response = CLIJSONOutput.UndoResponse(
                generatedAt: env.now(),
                fixID: result.fixID,
                kind: result.journalEntry.kind,
                backupDir: result.journalEntry.backupDir,
                status: result.journalEntry.status.rawValue,
                undoneAt: result.journalEntry.undoneAt
            )
            try CLIJSONOutput.printJSON(response)
        } else {
            print(
                "Undid fix \(result.fixID) (\(result.journalEntry.kind.rawValue)); restored from \(result.journalEntry.backupDir)"
            )
        }
    }
}
