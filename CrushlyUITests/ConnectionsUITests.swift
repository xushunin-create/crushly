import XCTest

/// Leave & delete, block/report from a conversation, notification routing and privacy settings.
final class ConnectionsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Opens to matching at McCarthy Quad, matches with Mina and lands in the chat.
    @MainActor
    private func matchedChat() -> XCUIApplication {
        let app = DemoLaunch.app(location: "upc-mccarthy-quad")
        app.launch()
        app.openToMatching()
        let mina = app.buttons["candidate.Mina"]
        XCTAssertTrue(mina.waitForExistence(timeout: 8))
        mina.reveal(in: app).tap()
        app.buttons["interest.send"].tap()
        XCTAssertTrue(app.buttons["reveal.message"].waitForExistence(timeout: 8))
        app.buttons["reveal.message"].tap()
        XCTAssertTrue(app.buttons["chat.options"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor
    func testLeaveAndDeleteConversation() throws {
        let app = matchedChat()
        app.buttons["chat.options"].tap()
        app.buttons["Leave & delete conversation"].tap()
        XCTAssertTrue(app.text(containing: "deleted for both of you").waitForExistence(timeout: 5))
        app.attach(self, "leave-confirm")
        // The dialog's button (not the menu item behind it).
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Leave & delete'"))
        confirm.element(boundBy: confirm.count - 1).tap()
        XCTAssertTrue(app.element("connections.empty").waitForExistence(timeout: 8), "back to an empty inbox")
    }

    @MainActor
    func testReportFromChatOffersEvidenceAndEndsConversation() throws {
        let app = matchedChat()
        app.buttons["chat.options"].tap()
        app.buttons["Report or block"].tap()
        XCTAssertTrue(app.text(containing: "Include messages").waitForExistence(timeout: 5))
        XCTAssertTrue(app.text(containing: "Only the messages you select").exists)
        app.attach(self, "report-sheet")
        app.buttons["safety.block"].tap()
        app.buttons["Block"].tap()
        XCTAssertTrue(app.element("connections.empty").waitForExistence(timeout: 8))
    }

    @MainActor
    func testNotificationRouteOpensConnections() throws {
        let app = DemoLaunch.app(extra: ["-CrushlyRoute", "connections"])
        app.launch()
        XCTAssertTrue(app.element("connections.empty").waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["consent.title"].exists, "opening a notification never asks for or grants consent")
    }

    @MainActor
    func testPauseFromPrivacySettings() throws {
        let app = DemoLaunch.app(location: "upc-mccarthy-quad")
        app.launch()
        app.openToMatching()
        app.buttons["tab.me"].tap()
        app.buttons["me.privacy"].tap()
        XCTAssertTrue(app.buttons["privacy.pause"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.text(containing: "not end-to-end encrypted").reveal(in: app).exists, "privacy screen states it plainly")
        app.swipeDown(); app.swipeDown()
        app.buttons["privacy.pause"].tap()
        app.buttons["1 hour"].tap()
        XCTAssertTrue(app.buttons["privacy.resume"].waitForExistence(timeout: 5))
        app.buttons["tab.spaces"].tap()
        XCTAssertTrue(app.text(containing: "Campus matching paused").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["candidate.Mina"].exists)
    }
}
