import XCTest

/// Drives the real app (demo backend) through sign-in → terms → profile → Around.
final class OnboardingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testNewUserCanRegisterAndReachAround() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-CrushlyDemo"]
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
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Demo mode'")).firstMatch.exists)
        code.tap()
        code.typeText("123456")
        app.buttons["signin.verify"].tap()

        // Terms + age declaration.
        let continueButton = app.buttons["terms.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        XCTAssertFalse(continueButton.isEnabled)
        app.buttons["terms.age"].tap()
        app.buttons["terms.tos"].tap()
        app.buttons["terms.privacy"].tap()
        XCTAssertTrue(continueButton.isEnabled)
        continueButton.tap()

        // Profile.
        let firstName = app.textFields["profile.firstName"]
        XCTAssertTrue(firstName.waitForExistence(timeout: 5))
        firstName.tap()
        firstName.typeText("Avery")
        app.buttons["profile.samplePhoto"].tap()
        app.buttons["profile.save"].tapAfterScrolling(in: app)
        XCTAssertTrue(app.staticTexts["Still needed"].waitForExistence(timeout: 3), "missing fields are explained")
        app.swipeDown(velocity: .fast)
        app.swipeDown(velocity: .fast)
        for interest in ["Coffee", "Design", "Film"] {
            app.buttons[interest].tapAfterScrolling(in: app)
        }
        let answer = app.textFields["profile.promptAnswer"]
        answer.tapAfterScrolling(in: app)
        answer.typeText("Tacos after midnight.")
        snapshot(app, "profile-filled")
        app.buttons["profile.save"].tapAfterScrolling(in: app)

        // Lands on Around, not visible until Pulse is on.
        XCTAssertTrue(app.staticTexts["Your radius"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Enter the Radius"].exists)
        XCTAssertTrue(app.staticTexts["You're not visible"].exists)
        snapshot(app, "around-off")
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension XCUIElement {
    enum Direction { case up, down }

    func clearAndType(_ text: String) {
        tap()
        if let value = value as? String, !value.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        typeText(text)
    }

    /// Scrolls until the element is hittable, then taps it.
    func tapAfterScrolling(in app: XCUIApplication, direction: Direction = .up, attempts: Int = 8) {
        var remaining = attempts
        while !(exists && isHittable) && remaining > 0 {
            direction == .up ? app.swipeUp(velocity: .slow) : app.swipeDown(velocity: .slow)
            remaining -= 1
        }
        XCTAssertTrue(exists && isHittable, "\(self) not reachable")
        tap()
    }
}
