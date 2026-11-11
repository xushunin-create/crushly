import XCTest

/// Phase 3: Pulse lifecycle, Campus Spaces and Around (demo backend, seeded account).
final class PulseAroundUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-CrushlyDemo", "-CrushlyDemoSeeded"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your radius"].waitForExistence(timeout: 5))
    }

    private func enterRadius(space: String = "USC Village") {
        app.buttons["pulse.start"].firstMatch.tap()
        let row = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", space)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        app.buttons["pulse.confirmStart"].reveal(in: app).tap()
    }

    private func person(_ name: String) -> XCUIElement {
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    @MainActor
    func testEnterRadiusShowsEligiblePeopleThenPauseHidesThem() throws {
        XCTAssertTrue(app.staticTexts["You're not visible"].exists)
        enterRadius()

        XCTAssertTrue(app.staticTexts["Visible".uppercased()].waitForExistence(timeout: 5))
        XCTAssertTrue(person("Mina").waitForExistence(timeout: 5), "radar shows people in the same space")
        XCTAssertFalse(person("Taylor").exists, "paused people never appear")
        XCTAssertFalse(person("Jordan").exists, "shielded people never appear")
        XCTAssertFalse(person("Rio").exists, "people in other spaces never appear")
        XCTAssertTrue(app.staticTexts["Positions on the radar are decorative and don't reflect where anyone is."].exists)
        snapshot("radar")

        app.buttons["List"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'simulated'")).firstMatch.waitForExistence(timeout: 3),
                      "demo distances are labelled simulated")
        snapshot("list")

        person("Mina").tap()
        XCTAssertTrue(app.staticTexts["Mina, 22"].waitForExistence(timeout: 5))
        snapshot("profile")
        app.buttons["Close"].tap()

        app.buttons["pulse.pause"].tap()
        XCTAssertTrue(app.staticTexts["PAUSED · HIDDEN"].waitForExistence(timeout: 5))
        XCTAssertFalse(person("Mina").exists, "pausing hides Around immediately")
        snapshot("paused")

        app.buttons["pulse.resume"].tap()
        XCTAssertTrue(app.staticTexts["VISIBLE"].waitForExistence(timeout: 5))
        XCTAssertTrue(person("Mina").waitForExistence(timeout: 5))

        app.buttons["pulse.off"].tap()
        XCTAssertTrue(app.staticTexts["You're not visible"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testEventCodeOffersUntilEventEnds() throws {
        app.buttons["pulse.start"].tap()
        let code = app.textFields["pulse.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.tap()
        code.typeText("NOPE99")
        app.buttons["Join"].tap()
        XCTAssertTrue(app.staticTexts["That event code didn't work."].waitForExistence(timeout: 5))

        code.clearAndType("IYA2026")
        app.buttons["Join"].tap()
        let untilChip = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Until'")).firstMatch
        XCTAssertTrue(untilChip.waitForExistence(timeout: 5), "events with an end time offer 'until it ends'")
        untilChip.tap()
        snapshot("start-sheet-event")
        app.buttons["pulse.confirmStart"].reveal(in: app).tap()
        XCTAssertTrue(app.staticTexts["Iovine & Young Fall Mixer"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSessionExpiryHidesYouAndSaysSo() throws {
        enterRadius()
        XCTAssertTrue(person("Mina").waitForExistence(timeout: 5))

        app.buttons["Me"].tap()
        let skip = app.buttons["Skip ahead 30 minutes"]
        skip.reveal(in: app).tap()
        app.buttons["Around"].tap()

        XCTAssertTrue(app.staticTexts["Time's up — you're hidden"].waitForExistence(timeout: 5))
        XCTAssertFalse(person("Mina, 22").exists, "live radar/list is gone once the session expires")
        XCTAssertTrue(app.buttons["Mina, recently nearby"].exists, "recent encounters remain for Crossed Hearts")
        snapshot("expired")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
