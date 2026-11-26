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
        app.holdToSendInterest()
        XCTAssertTrue(app.buttons["reveal.message"].waitForExistence(timeout: 8))
        app.buttons["reveal.message"].tap()
        XCTAssertTrue(app.buttons["chat.options"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor
    func testReactReplyAndUnsend() throws {
        let app = matchedChat()
        let composer = app.textViews["chat.composer"].exists ? app.textViews["chat.composer"] : app.textFields["chat.composer"]
        composer.tap()
        composer.typeText("See you at Leavey?")
        app.buttons["chat.send"].tap()
        let sent = app.text(containing: "See you at Leavey?")
        XCTAssertTrue(sent.waitForExistence(timeout: 5))

        // Long-press: reaction bar + actions. React with a heart.
        sent.press(forDuration: 0.6)
        XCTAssertTrue(app.buttons["chat.react.❤️"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chat.action.unsend"].exists, "my own messages can be unsent")
        app.attach(self, "chat-long-press")
        app.buttons["chat.react.❤️"].tap()
        XCTAssertTrue(app.text(containing: "You reacted ❤️").waitForExistence(timeout: 5))

        // Reply to it.
        app.text(containing: "See you at Leavey?").press(forDuration: 0.6)
        app.buttons["chat.action.reply"].tap()
        XCTAssertTrue(app.text(containing: "Replying to yourself").waitForExistence(timeout: 5))
        composer.typeText("3rd floor")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.text(containing: "You: 3rd floor").waitForExistence(timeout: 5))
        XCTAssertTrue(app.text(containing: "Reply to you").exists, "the reply quotes the original")
        app.attach(self, "chat-reply")

        // Unsend the reply.
        app.text(containing: "You: 3rd floor").press(forDuration: 0.6)
        app.buttons["chat.action.unsend"].tap()
        app.buttons.matching(identifier: "chat.confirmUnsend").firstMatch.tap()
        XCTAssertTrue(app.element("chat.unsentNotice").waitForExistence(timeout: 5))
        XCTAssertFalse(app.text(containing: "You: 3rd floor").exists)
        XCTAssertFalse(app.buttons["chat.attach"].exists, "there is no way to send photos")
        app.attach(self, "chat-unsent")
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
