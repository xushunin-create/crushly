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
        app.buttons["keyboard.done"].tap()
        app.buttons["profile.samplePhoto"].reveal(in: app).tap()
        app.buttons["profile.save"].reveal(in: app).tap()
        XCTAssertTrue(app.staticTexts["Still needed"].waitForExistence(timeout: 5), "missing fields are explained")

        for interest in ["Coffee", "Design", "Film"] {
            app.buttons[interest].reveal(in: app).tap()
        }
        let answer = app.textFields["profile.promptAnswer"]
        answer.reveal(in: app).tap()
        answer.typeText("Tacos after midnight.")
        app.buttons["keyboard.done"].tap()
        snapshot(app, "profile-filled")
        app.buttons["profile.save"].reveal(in: app).tap()

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

    /// Scrolls with small drags (from the screen edge, away from buttons) until the element sits in the
    /// middle band of the screen — clear of the navigation bar, tab bar and keyboard — then returns it.
    @discardableResult
    func reveal(in app: XCUIApplication, attempts: Int = 14) -> XCUIElement {
        let height = app.frame.height
        for _ in 0..<attempts {
            var towardTop = true
            if exists {
                let f = frame
                if isHittable, f.minY >= 120, f.maxY <= height - 90 { return self }
                towardTop = f.minY >= 120   // below the safe band (or covered) → scroll content up
            }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: towardTop ? 0.62 : 0.38))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: towardTop ? 0.42 : 0.58))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(exists && isHittable, "\(self) not reachable")
        return self
    }

    /// Scrolls until the element is hittable, then taps it.
    func tapAfterScrolling(in app: XCUIApplication, direction: Direction = .up, attempts: Int = 8) {
        var remaining = attempts
        while !(exists && isHittable) && remaining > 0 {
            direction == .up ? app.swipeUp(velocity: .slow) : app.swipeDown(velocity: .slow)
            remaining -= 1
        }
        // Keep it clear of the navigation bar, where taps land on the bar instead.
        var nudges = 3
        while exists && frame.minY < 140 && nudges > 0 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
            nudges -= 1
        }
        XCTAssertTrue(exists && isHittable, "\(self) not reachable")
        tap()
    }
}
