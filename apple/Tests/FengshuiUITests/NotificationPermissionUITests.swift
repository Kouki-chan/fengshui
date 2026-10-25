import XCTest

/// Grants the real notification permission on this simulator (simctl can't), so the unit
/// test that checks a real pending request's trigger time can run. scripts/test_all.sh
/// runs this before the unit tests; the grant persists on the simulator.
@MainActor
final class NotificationPermissionUITests: XCTestCase {
    func testGrantNotificationPermission() {
        let app = XCUIApplication()
        app.launchArguments += ["-FengshuiTestMode", "new_user", "-FengshuiRealNotifications"]
        app.launch()
        app.buttons["onboarding.start"].tap()
        app.buttons["onboarding.health"].tap()
        let rec = app.buttons["rec.continue"]
        XCTAssertTrue(app.switches["rec.accel"].waitForExistence(timeout: 5))
        while !rec.isHittable { app.swipeUp() }
        rec.tap()
        app.buttons["places.continue"].tap()
        app.buttons["sleep.continue"].tap()
        app.buttons["onboarding.notifications"].tap()
        // The system alert belongs to SpringBoard. If permission was already decided, there is none.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        XCTAssertTrue(app.buttons["backfill.continue"].waitForExistence(timeout: 20))
    }
}
