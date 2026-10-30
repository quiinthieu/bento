import BentoCore
import Testing

@testable import BentoUI

struct RootWindowTests {
    @Test("Default window configuration derives title from Product.name")
    func defaultWindowTitleMatchesProductName() {
        let config = RootWindowConfiguration()
        #expect(config.windowTitle == Product.name)
    }

    @Test("Overriding productName renames window title")
    func customProductNameRenamesWindowTitle() {
        let config = RootWindowConfiguration(productName: "AgentBudgetStudio")
        #expect(config.windowTitle == "AgentBudgetStudio")
    }

    @Test("RootView constructs cleanly on MainActor")
    @MainActor
    func rootViewConstructs() {
        let config = RootWindowConfiguration(productName: "AgentBudgetStudio")
        let view = RootView(configuration: config)
        #expect(view.configuration.windowTitle == "AgentBudgetStudio")
    }
}
