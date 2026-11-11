import XCTest

/// Phase 4: Heart Signals, anonymous receipts and the Heart Sync reveal (demo backend, seeded account).
final class SignalsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-CrushlyDemo", "-CrushlyDemoSeeded"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your radius"].waitForExistence(timeout: 5))
        app.buttons["pulse.start"].tap()
        let village = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'USC Village'")).firstMatch
        XCTAssertTrue(village.waitForExistence(timeout: 5))
        village.tap()
        app.buttons["pulse.confirmStart"].reveal(in: app).tap()
        XCTAssertTrue(app.staticTexts["VISIBLE"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilGone(app.buttons["pulse.confirmStart"]), "start sheet should finish closing")
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func open(_ name: String) {
        let dot = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "\(name),")).firstMatch
        XCTAssertTrue(dot.waitForExistence(timeout: 5), "\(name) should be in Around")
        dot.tap()
        XCTAssertTrue(app.buttons["signal.send"].waitForExistence(timeout: 5))
    }

    private var revealHeadline: XCUIElement {
        app.descendants(matching: .any)["reveal.headline"]
    }

    @MainActor
    func testOneSidedSignalStaysAnonymousAndCountsDown() throws {
        open("Noah")
        app.buttons["signal.send"].tap()
        let caption = app.staticTexts["signal.caption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        XCTAssertTrue(NSPredicate(format: "label BEGINSWITH 'Sent privately'").evaluate(with: caption)
                      || app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Sent privately'")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["signal.send"].isEnabled, "no repeat signals to the same person")
        snapshot("signal-sent")
        app.buttons["Close"].tap()
        XCTAssertTrue(waitUntilGone(app.buttons["signal.send"]))

        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '4 of 5 signals left'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(revealHeadline.exists, "a one-sided signal never produces a reveal")

        // Mina signalled us earlier: shown only as an anonymous receipt.
        app.buttons["tab.signals"].tap()
        XCTAssertTrue(app.staticTexts["Someone nearby noticed you."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Mina'")).firstMatch.exists,
                       "the receipt never names the sender")
        snapshot("receipts")
        app.buttons["receipts.notNow"].tap()
        XCTAssertTrue(waitUntilGone(app.staticTexts["Someone nearby noticed you."]), "Not Right Now sets receipts aside")
    }

    @MainActor
    func testMutualSignalShowsFullScreenHeartSync() throws {
        open("Mina")
        app.buttons["signal.send"].tap()

        XCTAssertTrue(revealHeadline.waitForExistence(timeout: 8), "reciprocal signal reveals Heart Sync")
        let eyebrow = app.staticTexts.matching(NSPredicate(format: "label ==[c] 'heart sync'")).firstMatch
        if !eyebrow.exists { print(app.debugDescription) }
        XCTAssertTrue(eyebrow.exists)
        XCTAssertFalse(app.buttons["tab.signals"].isHittable, "bottom navigation is hidden during the reveal")
        XCTAssertTrue(app.buttons["reveal.find"].exists)
        snapshot("heart-sync")

        app.buttons["reveal.stay"].tap()
        XCTAssertTrue(waitUntilGone(revealHeadline), "Stay in the Moment dismisses the reveal")

        app.buttons["tab.signals"].tap()
        XCTAssertTrue(app.staticTexts["MATCHED"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Mina"].exists)
    }

    @MainActor
    func testDelayedReplyRevealsAutomaticallyAndConnectLaterSaves() throws {
        open("Alex")
        app.buttons["signal.send"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Sent privately'")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        XCTAssertTrue(waitUntilGone(app.buttons["signal.send"]))

        // Alex signals back ~20 s later; the app discovers it on its own.
        XCTAssertTrue(revealHeadline.waitForExistence(timeout: 45), "delayed mutual signal should reveal without user action")
        app.buttons["reveal.later"].tap()
        XCTAssertTrue(app.staticTexts["The timing isn't right yet."].waitForExistence(timeout: 5))
        snapshot("connect-later")
        app.buttons["Done"].tap()

        app.buttons["tab.signals"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Find Later'")).firstMatch.waitForExistence(timeout: 5))
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
