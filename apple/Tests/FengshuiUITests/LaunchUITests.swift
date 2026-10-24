import XCTest

final class LaunchUITests: XCTestCase {
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launchArguments += ["-FengshuiTestMode", "new_user"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }
}
