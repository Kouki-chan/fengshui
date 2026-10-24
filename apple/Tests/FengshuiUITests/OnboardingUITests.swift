import XCTest

/// Gates: onboarding → places → backfill progress → debug counts (Phase 1/2), in test mode.
@MainActor
final class OnboardingUITests: XCTestCase {
    func waitEnabled(_ e: XCUIElement, _ seconds: Double = 60) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !e.isEnabled && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        return e.isEnabled
    }

    func setPlace(_ app: XCUIApplication, _ id: String, name: String? = nil) {
        app.buttons[id].tap()
        if let name {
            let field = app.textFields["placeEditor.name"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(name)
        }
        app.buttons["placeEditor.current"].tap()
        let save = app.buttons["placeEditor.save"]
        XCTAssertTrue(waitEnabled(save, 5))
        save.tap()
    }

    func testOnboardingPlacesBackfillAndDebugCounts() {
        let app = XCUIApplication()
        app.launchArguments += ["-FengshuiTestMode", "typical_week"]
        app.launch()

        app.buttons["onboarding.start"].tap()
        app.buttons["onboarding.health"].tap()

        // Recording preferences (Phase 3): keep the defaults.
        let recContinue = app.buttons["rec.continue"]
        XCTAssertTrue(app.switches["rec.accel"].waitForExistence(timeout: 5))
        while !recContinue.isHittable { app.swipeUp() }
        recContinue.tap()

        // Places: Home + Work from "current location", one named custom place.
        XCTAssertTrue(app.buttons["places.set.home"].waitForExistence(timeout: 5))
        setPlace(app, "places.set.home")
        XCTAssertTrue(app.buttons["places.set.home"].label.contains("✓"))
        setPlace(app, "places.set.work")
        setPlace(app, "places.addCustom", name: "Climbing gym")
        XCTAssertTrue(app.staticTexts["Climbing gym"].waitForExistence(timeout: 5))
        app.buttons["places.continue"].tap()

        XCTAssertTrue(app.progressIndicators["backfill.progress"].waitForExistence(timeout: 10))
        let cont = app.buttons["backfill.continue"]
        XCTAssertTrue(waitEnabled(cont), "backfill did not finish within 60 s")
        XCTAssertTrue(app.staticTexts["backfill.count"].label.contains("samples"))
        cont.tap()

        app.tabBars.buttons["Settings"].tap()
        app.buttons["settings.debug"].tap()
        let hr = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'heart_rate'")).firstMatch
        XCTAssertTrue(hr.waitForExistence(timeout: 10))

        // Places persisted and visible in Settings.
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["settings.places"].tap()
        XCTAssertTrue(app.staticTexts["Climbing gym"].waitForExistence(timeout: 5))
    }
}
