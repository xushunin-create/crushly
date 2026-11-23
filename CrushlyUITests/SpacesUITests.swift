import XCTest

/// Spaces end to end on the demo fixture with a simulated location at a real (draft) campus zone.
final class SpacesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testConsentSheetAndStayingInvisible() throws {
        let app = DemoLaunch.app(location: "upc-mccarthy-quad")
        app.launch()
        app.turnOnAndWaitForConsent()
        XCTAssertTrue(app.text(containing: "You're at McCarthy Quad.").exists)
        XCTAssertTrue(app.text(containing: "Your precise location is never shown.").exists)
        XCTAssertTrue(app.text(containing: "may infer you're in the same campus space").exists)
        app.attach(self, "consent-sheet")

        app.buttons["consent.invisible"].tap()
        XCTAssertTrue(app.text(containing: "chose to stay invisible for this visit").waitForExistence(timeout: 5))
        XCTAssertFalse(app.element("candidate.Mina").exists, "no candidates while invisible")
        // Changing your mind is an explicit choice on the status card.
        XCTAssertTrue(app.buttons["status.open"].exists)
    }

    @MainActor
    func testOpenInterestMatchAndChat() throws {
        let app = DemoLaunch.app(location: "upc-mccarthy-quad")
        app.launch()
        app.openToMatching()
        app.attach(self, "participating")

        XCTAssertTrue(app.element("spaces.receipt").waitForExistence(timeout: 10), "Someone here is interested")
        let mina = app.buttons["candidate.Mina"]
        XCTAssertTrue(mina.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["candidate.Jordan"].exists, "preferences apply both ways")
        mina.reveal(in: app).tap()

        let interest = app.buttons["interest.send"]
        XCTAssertTrue(interest.waitForExistence(timeout: 5))
        interest.press(forDuration: 0.7)

        // Mina was already interested: Heart Sync.
        XCTAssertTrue(app.element("reveal.headline").waitForExistence(timeout: 8))
        app.attach(self, "heart-sync")
        app.buttons["reveal.message"].tap()

        let composer = app.textViews["chat.composer"].exists ? app.textViews["chat.composer"] : app.textFields["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        composer.tap()
        composer.typeText("Hi Mina!")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.text(containing: "Hi Mina!").waitForExistence(timeout: 5))
        XCTAssertTrue(app.text(containing: "Okay, this is fun").waitForExistence(timeout: 15), "scripted reply arrives")
        app.attach(self, "chat")
    }

    @MainActor
    func testGoInvisibleWhileParticipating() throws {
        let app = DemoLaunch.app(location: "upc-mccarthy-quad")
        app.launch()
        app.openToMatching()
        app.buttons["status.goInvisible"].tap()
        XCTAssertTrue(app.text(containing: "chose to stay invisible for this visit").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["candidate.Mina"].exists)
    }

    @MainActor
    func testQuietSpaceShowsNoCount() throws {
        let app = DemoLaunch.app(location: "usc-village-great-lawn")
        app.launch()
        app.openToMatching()
        XCTAssertTrue(app.element("spaces.quiet").waitForExistence(timeout: 8))
        XCTAssertFalse(app.text(containing: "1 ").exists && app.text(containing: "people here").exists, "no counts")
        app.attach(self, "quiet")
    }

    @MainActor
    func testOutsideSupportedSpaces() throws {
        let app = DemoLaunch.app(location: "outside")
        app.launch()
        app.buttons["status.turnOn"].tap()
        XCTAssertTrue(app.text(containing: "Outside supported spaces").waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["consent.title"].waitForExistence(timeout: 10), "no prompt outside a space")
    }

    @MainActor
    func testPermissionStatesAreExplained() throws {
        let denied = DemoLaunch.app(location: "upc-mccarthy-quad", auth: "denied")
        denied.launch()
        denied.buttons["status.turnOn"].tap()
        XCTAssertTrue(denied.text(containing: "Location is off for Crushly").waitForExistence(timeout: 5))
        XCTAssertTrue(denied.buttons["Open Settings"].exists)
        denied.terminate()

        let approximate = DemoLaunch.app(location: "upc-mccarthy-quad", auth: "approximate")
        approximate.launch()
        approximate.buttons["status.turnOn"].tap()
        XCTAssertTrue(approximate.text(containing: "Precise location needed").waitForExistence(timeout: 5))
        approximate.buttons["Allow precise location for now"].tap()
        XCTAssertTrue(approximate.staticTexts["consent.title"].waitForExistence(timeout: 20), "precise access → detection works")
    }

    @MainActor
    func testHowMatchingWorksIsHonest() throws {
        let app = DemoLaunch.app()
        app.launch()
        app.element("spaces.howItWorks").reveal(in: app).tap()
        XCTAssertTrue(app.navigationBars["How matching works"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.text(containing: "can infer you were in the same campus space").reveal(in: app).exists)
        XCTAssertTrue(app.text(containing: "not end-to-end encrypted").reveal(in: app).exists)
        XCTAssertTrue(app.text(containing: "isn't endorsed by the University of Southern California").reveal(in: app).exists)
    }
}
