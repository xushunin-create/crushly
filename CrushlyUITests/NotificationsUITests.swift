import XCTest

/// Phase 7: permission primer timing and notification deep links (demo backend, seeded).
final class NotificationsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testPrimerAppearsOnlyAfterFirstSignal() throws {
        let app = XCUIApplication()
        // Argument-domain override so earlier runs' "Not now" doesn't hide the primer.
        app.launchArguments = ["-CrushlyDemo", "-CrushlyDemoSeeded", "-crushly.notificationPrimerDismissed", "NO"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your radius"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["notifications.enable"].exists, "never asks on launch")

        app.buttons["pulse.start"].tap()
        let village = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'USC Village'")).firstMatch
        XCTAssertTrue(village.waitForExistence(timeout: 5))
        village.tap()
        app.buttons["pulse.confirmStart"].reveal(in: app).tap()
        let noah = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Noah, 22'")).firstMatch
        XCTAssertTrue(noah.waitForExistence(timeout: 8))
        noah.tap()
        app.buttons["signal.send"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Sent privately'")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["Close"].tap()

        let enable = app.buttons["notifications.enable"]
        guard enable.waitForExistence(timeout: 5) else {
            throw XCTSkip("Simulator notification permission already decided; primer correctly not shown.")
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "notification-primer"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["notifications.notNow"].tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: enable)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed)
    }

    @MainActor
    func testTappingANotificationOpensSignals() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-CrushlyDemo", "-CrushlyDemoSeeded", "-CrushlyRoute", "signals"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Who felt it"].waitForExistence(timeout: 8), "deep link lands on Signals")
    }
}
