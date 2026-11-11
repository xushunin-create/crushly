import XCTest

/// Phase 5: Crossed Hearts, Connect Later actions, Find Each Other and expiry (demo backend, seeded account).
final class ConnectionsUITests: XCTestCase {
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
        XCTAssertTrue(gone(app.buttons["pulse.confirmStart"]))
    }

    // MARK: Helpers

    private func gone(_ element: XCUIElement, timeout: TimeInterval = 8) -> Bool {
        let predicate = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [predicate], timeout: timeout) == .completed
    }

    private func button(startingWith prefix: String) -> XCUIElement {
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func text(containing fragment: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    private var revealHeadline: XCUIElement { app.descendants(matching: .any)["reveal.headline"] }

    private func signal(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        element.tap()
        let send = app.buttons["signal.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        XCTAssertTrue(revealHeadline.waitForExistence(timeout: 10), "a mutual signal shows the reveal")
    }

    private func matchWithMina() { signal(button(startingWith: "Mina, 22")) }

    private func openConnection(_ name: String) {
        app.buttons["tab.signals"].tap()
        let row = button(startingWith: name)
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
    }

    private func skip(_ title: String) {
        app.buttons["tab.me"].tap()
        app.buttons[title].reveal(in: app).tap()
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Tests

    @MainActor
    func testCrossedHeartsFromRecentEncounterThenIncomingCoffee() throws {
        skip("Skip ahead 5 minutes")          // Jamie signals you, then leaves
        app.buttons["tab.around"].tap()
        signal(app.buttons["Jamie, recently nearby"])

        XCTAssertTrue(app.staticTexts["CROSSED HEARTS"].exists)
        XCTAssertTrue(text(containing: "You missed the moment").exists)
        XCTAssertFalse(app.buttons["reveal.find"].exists, "no meet-now offer when the moment has passed")
        snapshot("crossed-hearts")
        app.buttons["reveal.stay"].tap()
        XCTAssertTrue(gone(revealHeadline))

        app.buttons["tab.signals"].tap()
        XCTAssertTrue(app.staticTexts["CROSSED HEARTS"].waitForExistence(timeout: 5))
        openConnection("Jamie")
        XCTAssertTrue(app.staticTexts["They suggested coffee"].waitForExistence(timeout: 25), "incoming suggestion appears")
        XCTAssertFalse(button(startingWith: "Find Each Other Now").exists, "never offered for Crossed Hearts")
        snapshot("incoming-coffee")
        app.buttons["Accept"].tap()
        XCTAssertTrue(gone(app.staticTexts["They suggested coffee"]))
        XCTAssertTrue(text(containing: "suggest coffee · accepted").waitForExistence(timeout: 5))
    }

    @MainActor
    func testConnectLaterThenInstagramSwapNeedsConsent() throws {
        matchWithMina()
        app.buttons["reveal.later"].tap()
        XCTAssertTrue(app.staticTexts["The timing isn't right yet."].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        openConnection("Mina")
        XCTAssertFalse(text(containing: "@mina").exists, "no handle before consent")
        button(startingWith: "Swap Instagram").reveal(in: app).tap()
        XCTAssertTrue(text(containing: "Waiting").waitForExistence(timeout: 5))
        XCTAssertTrue(text(containing: "@mina.makes.playlists").waitForExistence(timeout: 25), "handle shared after she accepts")
        snapshot("instagram")
    }

    @MainActor
    func testFindEachOtherNeedsBothToAgree() throws {
        matchWithMina()
        app.buttons["reveal.find"].tap()
        let point = app.buttons["Tommy Trojan"]
        XCTAssertTrue(point.waitForExistence(timeout: 5))
        point.tap()
        XCTAssertTrue(text(containing: "No live location is shared").exists)
        button(startingWith: "Ask to meet at Tommy Trojan").tap()
        XCTAssertTrue(gone(revealHeadline))

        openConnection("Mina")
        XCTAssertTrue(app.staticTexts["Head to the meeting point"].waitForExistence(timeout: 25)
                      || text(containing: "Waiting for Mina").exists)
        XCTAssertTrue(app.staticTexts["Head to the meeting point"].waitForExistence(timeout: 25), "Find Mode starts only once she accepts")
        XCTAssertTrue(app.staticTexts["FIND MODE ON"].exists)
        snapshot("find-mode")
        app.buttons["We found each other"].tap()
        XCTAssertTrue(gone(app.staticTexts["FIND MODE ON"]))
        XCTAssertTrue(app.buttons["We met tonight"].isSelected)
    }

    @MainActor
    func testExpiredConnectionsMoveOutOfActiveSections() throws {
        matchWithMina()
        app.buttons["reveal.stay"].tap()
        XCTAssertTrue(gone(revealHeadline))
        skip("Skip ahead 25 hours")

        app.buttons["tab.signals"].tap()
        XCTAssertTrue(app.staticTexts["EXPIRED"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["MATCHED"].exists)
        snapshot("expired")
        openConnection("Mina")
        XCTAssertTrue(text(containing: "This connection expired").waitForExistence(timeout: 5))
        app.buttons["Remove"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(gone(app.staticTexts["EXPIRED"]))
    }
}
