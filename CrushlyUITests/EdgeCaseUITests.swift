import XCTest

/// Phase 8: edge cases that aren't part of a single feature journey.
final class EdgeCaseUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-CrushlyDemo", "-CrushlyDemoSeeded", "-crushly.notificationPrimerDismissed", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your radius"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testEmptySpaceShowsAnHonestEmptyState() throws {
        app.buttons["pulse.start"].tap()
        let tutor = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Tutor Campus Center'")).firstMatch
        XCTAssertTrue(tutor.waitForExistence(timeout: 5))
        tutor.tap()
        app.buttons["pulse.confirmStart"].reveal(in: app).tap()
        XCTAssertTrue(app.staticTexts["Quiet right now"].waitForExistence(timeout: 8), "no one nearby is explained, not blank")
    }

    @MainActor
    func testRejectedPhotoExplainsYouAreHidden() throws {
        app.buttons["tab.me"].tap()
        app.buttons["Simulate photo rejection"].reveal(in: app).tap()
        // Me is a lazy List: scroll back up so the profile card row is loaded again.
        app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Photo rejected'")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["tab.around"].tap()
        XCTAssertTrue(app.staticTexts["Your photo wasn't approved"].waitForExistence(timeout: 5))
        app.buttons["photo.rejected.update"].tap()
        XCTAssertTrue(app.buttons["profile.save"].waitForExistence(timeout: 5), "leads straight to the photo editor")
    }

    @MainActor
    func testSignalLimitIsClearlyCommunicated() throws {
        app.buttons["pulse.start"].tap()
        let village = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'USC Village'")).firstMatch
        XCTAssertTrue(village.waitForExistence(timeout: 5))
        village.tap()
        app.buttons["pulse.confirmStart"].reveal(in: app).tap()
        // Four people who never reciprocate, then Mina (instant match) — a match still uses a signal.
        for name in ["Noah", "Priya", "Marcus", "Elena", "Mina"] {
            let dot = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@ AND NOT (label CONTAINS 'recently')", "\(name),")).firstMatch
            XCTAssertTrue(dot.waitForExistence(timeout: 8), name)
            dot.tap()
            app.buttons["signal.send"].tap()
            if name == "Mina" {
                XCTAssertTrue(app.buttons["reveal.stay"].waitForExistence(timeout: 10))
                app.buttons["reveal.stay"].tap()
            } else {
                XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Sent privately'")).firstMatch.waitForExistence(timeout: 5))
                app.buttons["Close"].tap()
            }
            let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["signal.send"])
            _ = XCTWaiter().wait(for: [gone], timeout: 5)
        }
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '0 of 5 signals left'")).firstMatch.waitForExistence(timeout: 5))
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Alex, 21'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'used all 5 signals'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["signal.send"].isEnabled)
    }
}
