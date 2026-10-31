import BentoCore
import SwiftUI

/// macOS menu bar commands ensuring every primary navigation and workspace action is reachable by keyboard (`PLAN.md` §6.7, §11 T15).
public struct BentoMenuCommands: Commands {
    private let model: BentoAppModel

    public init(model: BentoAppModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandMenu("Navigate") {
            ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element.id) { index, section in
                Button(section.title) {
                    model.selectSectionByShortcut(index: index + 1)
                }
                .keyboardShortcut(KeyEquivalent(section.shortcutDigit), modifiers: .command)
            }

            Divider()

            Button("Budget Tab") {
                model.selectedSection = .repos
                model.selectedRepoTab = .budget
            }
            .keyboardShortcut("1", modifiers: .control)

            Button("Resolution Tab") {
                model.selectedSection = .repos
                model.selectedRepoTab = .resolution
            }
            .keyboardShortcut("2", modifiers: .control)

            Button("Usage Tab") {
                model.selectedSection = .repos
                model.selectedRepoTab = .usage
            }
            .keyboardShortcut("3", modifiers: .control)

            Button("Hygiene Tab") {
                model.selectedSection = .repos
                model.selectedRepoTab = .hygiene
            }
            .keyboardShortcut("4", modifiers: .control)

            Divider()

            Button("Next Repository") {
                model.selectNextRepository()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])

            Button("Previous Repository") {
                model.selectPreviousRepository()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])

            Button("Next Repository Tab") {
                model.cycleRepoTab(forward: true)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Button("Previous Repository Tab") {
                model.cycleRepoTab(forward: false)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])

            Button("Next Agent") {
                model.cycleSelectedAgent(forward: true)
            }
            .keyboardShortcut("]", modifiers: [.command, .option])

            Button("Previous Agent") {
                model.cycleSelectedAgent(forward: false)
            }
            .keyboardShortcut("[", modifiers: [.command, .option])
        }

        CommandMenu("Workspace") {
            Button("Rescan Workspace") {
                Task {
                    await model.refreshAll()
                }
            }
            .keyboardShortcut("r", modifiers: .command)

            Button(model.isInspectorPresented ? "Hide Inspector" : "Show Inspector") {
                model.isInspectorPresented.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])

            Divider()

            Button("Privacy & First-Run Guide…") {
                model.isShowingOnboarding = true
            }
        }
    }
}
