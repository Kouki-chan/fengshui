import XCTest

/// Gates: onboarding → places → backfill progress → debug counts (Phase 1/2), in test mode.
@MainActor
final class OnboardingUITests: XCTestCase {
    func waitEnabled(_ e: XCUIElement, _ seconds: Double = 60) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !e.isEnabled && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        return e.isEnabled
    }

    /// Settings is a long list: scroll until the row is on screen, then tap it.
    func tapScrolling(_ app: XCUIApplication, _ id: String) {
        let b = app.buttons[id]
        var tries = 0
        while !(b.exists && b.isHittable) && tries < 8 { app.swipeUp(); tries += 1 }
        b.tap()
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

        // Sleep questions (defaults) and notifications (fake center in test mode).
        XCTAssertTrue(app.buttons["sleep.continue"].waitForExistence(timeout: 5))
        app.buttons["sleep.continue"].tap()
        XCTAssertTrue(app.buttons["onboarding.notifications"].waitForExistence(timeout: 5))
        app.buttons["onboarding.notifications"].tap()

        XCTAssertTrue(app.progressIndicators["backfill.progress"].waitForExistence(timeout: 10))
        let cont = app.buttons["backfill.continue"]
        XCTAssertTrue(waitEnabled(cont), "backfill did not finish within 60 s")
        XCTAssertTrue(app.staticTexts["backfill.count"].label.contains("samples"))
        cont.tap()

        // Today shows tonight's plan once the post-onboarding engine run finishes.
        XCTAssertTrue(app.staticTexts["Start winding down"].waitForExistence(timeout: 30))

        // Data tab: live tiles from the backfilled samples; a type opens its detail.
        app.tabBars.buttons["Data"].tap()
        let hrTile = app.buttons["data.vital.heart_rate"]
        XCTAssertTrue(hrTile.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["data.watch"].exists)
        hrTile.tap()
        XCTAssertTrue(app.navigationBars["Heart rate"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()

        // Reports tab: a data-only report (no API key in test mode) opens as a PDF and lands in the inbox.
        app.tabBars.buttons["Reports"].tap()
        let create = app.buttons["report.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        XCTAssertTrue(waitEnabled(create), "default labels should be selected")
        create.tap()
        XCTAssertTrue(app.descendants(matching: .any)["report.pdf"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["report.share"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["inbox.badge"].waitForExistence(timeout: 5))

        // Bell: the report-ready message; select it and delete the selection.
        app.buttons["inbox.button"].firstMatch.tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'inbox.row.report-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.buttons["inbox.select"].tap()
        app.buttons["inbox.selectAll"].tap()
        app.buttons["inbox.deleteSelected"].tap()
        XCTAssertTrue(app.staticTexts["No notifications"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["inbox.badge"].waitForExistence(timeout: 2))

        app.tabBars.buttons["Settings"].tap()
        tapScrolling(app, "settings.debug")
        let hr = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'heart_rate'")).firstMatch
        XCTAssertTrue(hr.waitForExistence(timeout: 10))

        // Places persisted and visible in Settings.
        app.navigationBars.buttons.firstMatch.tap()
        tapScrolling(app, "settings.places")
        XCTAssertTrue(app.staticTexts["Climbing gym"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()

        // Diagnostics runs in test mode (no server configured → not uploaded, but checks shown).
        tapScrolling(app, "settings.diagnostics")
        app.buttons["diag.run"].tap()
        XCTAssertTrue(app.staticTexts["diag.status"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["diag.check.healthkit_types_readable"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()

        // Ask tab: preset questions listed; without a key it explains what to do.
        app.tabBars.buttons["Ask"].tap()
        XCTAssertTrue(app.navigationBars["Ask FengShui Agent"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["How active was I today?"].waitForExistence(timeout: 5))
        app.buttons["How active was I today?"].tap()
        XCTAssertTrue(app.staticTexts["ask.answer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["ask.answer"].label.contains("API key"))
    }
}
