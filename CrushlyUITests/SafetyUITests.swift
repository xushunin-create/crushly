import XCTest

/// Phase 6: Protect My Heart, block/unblock, report, Me settings and account deletion (demo backend, seeded).
final class SafetyUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-CrushlyDemo", "-CrushlyDemoSeeded"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your radius"].waitForExistence(timeout: 5))
    }

    private func enterVillage() {
        app.buttons["pulse.start"].tap()
        let village = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'USC Village'")).firstMatch
        XCTAssertTrue(village.waitForExistence(timeout: 5))
        village.tap()
        app.buttons["pulse.confirmStart"].reveal(in: app).tap()
        XCTAssertTrue(app.staticTexts["VISIBLE"].waitForExistence(timeout: 5))
        XCTAssertTrue(gone(app.buttons["pulse.confirmStart"]))
    }

    private func gone(_ element: XCUIElement, timeout: TimeInterval = 8) -> Bool {
        let predicate = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [predicate], timeout: timeout) == .completed
    }

    private func person(_ name: String) -> XCUIElement {
        // Live radar/list entries only — "Recently in your radius" entries are expected to remain.
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@ AND NOT (label CONTAINS 'recently')", "\(name),")).firstMatch
    }

    private func openSafety(for name: String) {
        let dot = person(name)
        XCTAssertTrue(dot.waitForExistence(timeout: 5))
        dot.tap()
        let options = app.buttons["Safety options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        options.tap()
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testProtectMyHeartHidesImmediatelyAndNeverAutoResumes() throws {
        enterVillage()
        XCTAssertTrue(person("Mina").waitForExistence(timeout: 5))
        app.buttons["Protect My Heart"].tap()
        let oneHour = app.buttons["1 hour"]
        XCTAssertTrue(oneHour.waitForExistence(timeout: 5))
        oneHour.tap()

        XCTAssertTrue(app.staticTexts["You're hidden"].waitForExistence(timeout: 5))
        XCTAssertTrue(gone(person("Mina")), "Around is gone immediately")
        XCTAssertFalse(app.buttons["pulse.start"].exists, "can't start a session while protected")
        snapshot("shield")

        app.buttons["Leave Protect My Heart"].tap()
        XCTAssertTrue(app.staticTexts["You're not visible"].waitForExistence(timeout: 5),
                      "leaving Protect My Heart doesn't make you visible again")
        XCTAssertTrue(app.buttons["pulse.start"].exists)
    }

    @MainActor
    func testBlockRemovesThemAndUnblockRestores() throws {
        enterVillage()
        openSafety(for: "Priya")
        app.buttons["Block Priya"].tap()
        let confirm = app.buttons["Block"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(gone(app.buttons["signal.send"]), "profile closes after blocking")
        XCTAssertTrue(gone(person("Priya")), "blocked people disappear from Around")

        app.buttons["tab.me"].tap()
        app.buttons["Blocked people"].reveal(in: app).tap()
        XCTAssertTrue(app.staticTexts["Priya"].waitForExistence(timeout: 5))
        snapshot("blocked-list")
        app.buttons["Unblock"].tap()
        XCTAssertTrue(app.staticTexts["You haven't blocked anyone."].waitForExistence(timeout: 5))

        app.buttons["tab.around"].tap()
        XCTAssertTrue(person("Priya").waitForExistence(timeout: 12), "unblocked people can appear again")
    }

    @MainActor
    func testReportRequiresAReasonAndAlsoBlocks() throws {
        enterVillage()
        openSafety(for: "Marcus")
        let submit = app.buttons["Submit report"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled, "a reason is required")
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Reason'")).firstMatch.tap()
        let spam = app.buttons["Spam"]
        XCTAssertTrue(spam.waitForExistence(timeout: 5))
        spam.tap()
        XCTAssertTrue(submit.isEnabled)
        snapshot("report")
        submit.tap()
        XCTAssertTrue(gone(app.buttons["signal.send"]))
        XCTAssertTrue(gone(person("Marcus")), "reporting also blocks")
    }

    @MainActor
    func testMeShowsHonestSettingsAndSafetyTips() throws {
        app.buttons["tab.me"].tap()
        XCTAssertTrue(app.staticTexts["Photo review pending"].waitForExistence(timeout: 5), "no verified badge while pending")
        XCTAssertTrue(app.staticTexts["Selfie verification: not available yet"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Distance-based discovery isn'")).firstMatch.exists,
                      "unsupported settings are explained, not faked")
        app.buttons["Safety tips"].reveal(in: app).tap()
        XCTAssertTrue(app.staticTexts["Meet in public"].waitForExistence(timeout: 5))
        snapshot("safety-tips")
    }

    @MainActor
    func testDeleteAccountReturnsToSignIn() throws {
        app.buttons["tab.me"].tap()
        app.buttons["Delete account and data"].reveal(in: app).tap()
        let confirm = app.buttons["Delete permanently"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.textFields["signin.email"].waitForExistence(timeout: 8))
    }
}
