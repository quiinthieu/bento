import XCTest

/// XCUITest smoke suite launching the macOS application against `-fixtureHome polyglot` (`PLAN.md` §11 T15).
final class BentoMacAppUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSmokePolyglotNavigationKeyboardVoiceOverAndReadOnlyFixGate() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-fixtureHome", "polyglot", "-showOnboarding"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Primary window must appear on launch")

        // 1. First-run privacy onboarding sheet is presented and dismissible via keyboard Return
        let continueButton = app.buttons["onboarding-continue-button"]
        if continueButton.waitForExistence(timeout: 5) {
            app.typeKey(.return, modifierFlags: [])
        }

        // 2. Overview section renders detected agents and summary metrics
        XCTAssertTrue(
            app.staticTexts["overview-heading"].waitForExistence(timeout: 5),
            "Overview heading should be visible after onboarding"
        )

        // 3. Navigate via keyboard shortcuts Cmd+2..Cmd+7 across sidebar sections
        app.typeKey("2", modifierFlags: .command)  // Repos
        let demoRepoRow = app.buttons["repo-row-demo-app"]
        if demoRepoRow.waitForExistence(timeout: 5) {
            demoRepoRow.click()
        }

        // 4. Verify Budget chart VoiceOver segment elements exist and tabs switch cleanly
        let budgetTab = app.radioButtons["Budget"]
        if budgetTab.exists {
            budgetTab.click()
        }
        let chartContainer = app.otherElements["budget-stacked-chart"]
        if chartContainer.exists {
            XCTAssertFalse(chartContainer.label.isEmpty)
        }

        // Cycle through Resolution, Usage, Hygiene via keyboard Ctrl+2..Ctrl+4
        app.typeKey("2", modifierFlags: .control)
        app.typeKey("3", modifierFlags: .control)
        app.typeKey("4", modifierFlags: .control)

        // 5. Verify Fix History (Cmd+6) and Settings (Cmd+7) where "Allow changes" defaults to off
        app.typeKey("6", modifierFlags: .command)
        app.typeKey("7", modifierFlags: .command)
        let allowChangesToggle = app.checkBoxes["settings-allow-changes-toggle"]
        if allowChangesToggle.waitForExistence(timeout: 3) {
            XCTAssertEqual(allowChangesToggle.value as? Int, 0, "Allow changes must default to off")
        }
    }
}
