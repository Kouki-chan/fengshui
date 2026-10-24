import XCTest

/// Gate: onboarding → backfill progress → debug counts, in test mode (no permission dialogs).
@MainActor
final class OnboardingUITests: XCTestCase {
    func testOnboardingBackfillAndDebugCounts() {
        let app = XCUIApplication()
        app.launchArguments += ["-FengshuiTestMode", "typical_week"]
        app.launch()

        app.buttons["onboarding.start"].tap()
        app.buttons["onboarding.health"].tap()

        XCTAssertTrue(app.progressIndicators["backfill.progress"].waitForExistence(timeout: 10))
        let cont = app.buttons["backfill.continue"]
        let deadline = Date().addingTimeInterval(60)
        while !cont.isEnabled && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(cont.isEnabled, "backfill did not finish within 60 s")
        XCTAssertTrue(app.staticTexts["backfill.count"].label.contains("samples"))
        cont.tap()

        app.tabBars.buttons["Settings"].tap()
        app.buttons["settings.debug"].tap()
        let hr = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'heart_rate'")).firstMatch
        XCTAssertTrue(hr.waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells.containing(.staticText, identifier: "heart_rate").firstMatch.exists
                      || hr.exists)
    }
}
