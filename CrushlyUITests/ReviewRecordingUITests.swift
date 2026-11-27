import XCTest

/// Not a regression test: a slowed-down walk through the in-space flow, used to record the App Review video
/// (`xcrun simctl io <device> recordVideo` while this runs). Skipped unless CRUSHLY_RECORD_REVIEW=1.
final class ReviewRecordingUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func pause(_ seconds: Double = 2.5) { usleep(UInt32(seconds * 1_000_000)) }

    /// Radar avatars drift, so a tap can land on a neighbour. Open Mina's profile, retrying until it's hers.
    @MainActor
    private func openMina(_ app: XCUIApplication) {
        let mina = app.buttons["candidate.Mina"]
        for _ in 0..<5 {
            mina.reveal(in: app).tap()
            if app.text(containing: "Mina, 22").waitForExistence(timeout: 4) { return }
            app.swipeDown(velocity: .fast)   // wrong person: dismiss the sheet and try again
            pause(1.5)
        }
        XCTFail("couldn't open Mina's profile")
    }

    @MainActor
    func testRecordInSpaceFlow() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CRUSHLY_RECORD_REVIEW"] == "1", "recording only")
        let app = DemoLaunch.app(location: "upc-mccarthy-quad", extra: ["-CrushlyHideDemoBadge"])
        app.launch()
        pause(3)

        // Arrive in a campus space, turn on matching, consent for this visit.
        app.turnOnAndWaitForConsent()
        pause(4)
        app.buttons["consent.open"].tap()
        XCTAssertTrue(app.text(containing: "Open to matching during this visit").waitForExistence(timeout: 8))
        pause(3)

        // People here who also opted in; a private "someone is interested" receipt.
        XCTAssertTrue(app.element("spaces.receipt").waitForExistence(timeout: 10))
        let mina = app.buttons["candidate.Mina"]
        XCTAssertTrue(mina.waitForExistence(timeout: 8))
        pause(3)
        openMina(app)
        pause(3)

        // Private interest; it's mutual, so they match.
        app.holdToSendInterest()
        XCTAssertTrue(app.element("reveal.headline").waitForExistence(timeout: 8))
        pause(4)
        app.buttons["reveal.message"].tap()

        // One-to-one chat.
        let composer = app.textViews["chat.composer"].exists ? app.textViews["chat.composer"] : app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        pause(2)
        composer.tap()
        composer.typeText("Hi Mina! Saw you at McCarthy Quad")
        pause(1)
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.text(containing: "Okay, this is fun").waitForExistence(timeout: 20))
        pause(4)

        // Safety tools in the chat menu.
        let options = app.buttons["chat.options"]
        if options.waitForExistence(timeout: 3) {
            options.tap()
            pause(4)
        }
    }

    /// App Store screenshots: writes full-resolution PNGs to $CRUSHLY_SHOT_DIR. Skipped unless it is set.
    @MainActor
    func testCaptureStoreScreenshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["CRUSHLY_SHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("screenshots only")
        }
        func shot(_ name: String) {
            pause(1.5)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        let app = DemoLaunch.app(location: "upc-mccarthy-quad", extra: ["-CrushlyHideDemoBadge"])
        app.launch()
        app.turnOnAndWaitForConsent()
        shot("1-consent")
        app.buttons["consent.open"].tap()
        XCTAssertTrue(app.element("spaces.receipt").waitForExistence(timeout: 10))
        let mina = app.buttons["candidate.Mina"]
        XCTAssertTrue(mina.waitForExistence(timeout: 8))
        shot("2-spaces")
        openMina(app)
        XCTAssertTrue(app.buttons["interest.send"].waitForExistence(timeout: 5))
        shot("3-profile")
        app.holdToSendInterest()
        XCTAssertTrue(app.element("reveal.headline").waitForExistence(timeout: 8))
        pause(2)
        shot("4-heart-sync")
        app.buttons["reveal.message"].tap()
        let composer = app.textViews["chat.composer"].exists ? app.textViews["chat.composer"] : app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        composer.tap()
        composer.typeText("Hi Mina! Leavey or Doheny?")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.text(containing: "Okay, this is fun").waitForExistence(timeout: 20))
        // Drop the keyboard by tapping empty space above the messages.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22)).tap()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
        shot("5-chat")
        let back = app.navigationBars.buttons.firstMatch
        if back.exists { back.tap() }
        app.buttons["tab.me"].tap()
        app.buttons["me.privacy"].tap()
        XCTAssertTrue(app.buttons["privacy.pause"].waitForExistence(timeout: 5))
        shot("6-privacy")
    }
}
