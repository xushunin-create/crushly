import XCTest

/// Drives the real app (demo fixture) through sign-in → terms → the four profile steps → Spaces.
final class OnboardingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testNewUserCanRegisterAndReachSpaces() throws {
        let app = DemoLaunch.app(seeded: false)
        app.launch()

        // Sign in with a USC address.
        let email = app.textFields["signin.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        email.typeText("avery@gmail.com")
        XCTAssertFalse(app.buttons["signin.sendCode"].isEnabled, "non-USC email must not be accepted")
        email.clearAndType("avery@usc.edu")
        app.buttons["signin.sendCode"].tap()

        let code = app.textFields["signin.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.tap()
        code.typeText("123456")
        app.buttons["signin.verify"].tap()

        // Terms + age declaration.
        let continueButton = app.buttons["terms.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        XCTAssertFalse(continueButton.isEnabled)
        app.buttons["terms.age"].tap()
        // Acceptances stay locked until each document has been scrolled to the end.
        XCTAssertFalse(app.buttons["terms.tos"].isEnabled)
        XCTAssertFalse(app.buttons["terms.privacy"].isEnabled)
        for (doc, id) in [("Terms of Service", "terms.tos"), ("Privacy Policy", "terms.privacy")] {
            app.buttons["Read \(doc)"].tap()
            let scroll = app.scrollViews["legal.scroll"]
            XCTAssertTrue(scroll.waitForExistence(timeout: 5))
            for _ in 0..<20 { scroll.swipeUp(velocity: .fast) }   // overshooting the bottom is harmless
            app.buttons["Done"].tap()
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons[id].isEnabled, "\(doc) should unlock after reading to the end")
            app.buttons[id].tap()
        }
        continueButton.tap()

        // Profile, one step at a time. Step 1: basics, with gender asked exactly once.
        let firstName = app.textFields["profile.firstName"]
        XCTAssertTrue(firstName.waitForExistence(timeout: 5))
        XCTAssertTrue(app.text(containing: "Step 1 of 4").exists)
        firstName.tap()
        firstName.typeText("Avery")
        app.buttons["keyboard.done"].tap()
        app.buttons["profile.next"].reveal(in: app).tap()
        XCTAssertTrue(app.staticTexts["Still needed"].waitForExistence(timeout: 5), "gender is required before continuing")
        XCTAssertEqual(app.buttons.matching(identifier: "prefs.matchAs.woman").count, 1, "only one place to pick your gender")
        app.buttons["prefs.matchAs.woman"].reveal(in: app).tap()
        app.attach(self, "profile-step-basics")
        app.buttons["profile.next"].reveal(in: app).tap()

        // Step 2: photos.
        XCTAssertTrue(app.text(containing: "Step 2 of 4").waitForExistence(timeout: 5))
        XCTAssertTrue(app.text(containing: "go live").exists, "photos are live right away, no review wait")
        app.buttons["profile.samplePhoto"].reveal(in: app).tap()
        XCTAssertTrue(app.text(containing: "Live").waitForExistence(timeout: 5))
        app.buttons["profile.next"].reveal(in: app).tap()

        // Step 3: interests and a prompt.
        XCTAssertTrue(app.text(containing: "Step 3 of 4").waitForExistence(timeout: 5))
        for interest in ["Coffee", "Design", "Film"] {
            app.buttons[interest].reveal(in: app).tap()
        }
        let answer = app.textFields["profile.promptAnswer"]
        answer.reveal(in: app).tap()
        answer.typeText("Tacos after midnight.")
        app.buttons["keyboard.done"].tap()
        app.buttons["profile.next"].reveal(in: app).tap()

        // Step 4: who you'd like to meet.
        XCTAssertTrue(app.text(containing: "Step 4 of 4").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["prefs.matchAs.woman"].exists, "gender is not asked a second time")
        app.buttons["profile.save"].reveal(in: app).tap()
        XCTAssertTrue(app.text(containing: "Show me").waitForExistence(timeout: 5))
        app.buttons["prefs.showMe.everyone"].reveal(in: app).tap()
        app.attach(self, "profile-step-looking-for")
        app.buttons["profile.save"].reveal(in: app).tap()

        // Spaces: invisible by default, location not used yet.
        XCTAssertTrue(app.buttons["status.turnOn"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.text(containing: "Invisible").exists)
        XCTAssertTrue(app.text(containing: "© OpenStreetMap contributors").exists)
        app.attach(self, "spaces-first-run")
    }
}
