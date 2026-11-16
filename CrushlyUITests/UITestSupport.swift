import XCTest

/// Shared launch configuration for the demo fixture. Every UI test runs against DemoBackend + simulated location
/// (never the live backend). `-crushly.campusMatchingOn NO` resets the persisted device toggle for each run.
enum DemoLaunch {
    static func app(seeded: Bool = true, location: String? = nil, auth: String = "precise", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-CrushlyDemo", "-crushly.campusMatchingOn", "NO", "-crushly.notificationPrimerDismissed", "YES",
                    "-CrushlyDemoLocationAuth", auth]
        if seeded { args.append("-CrushlyDemoSeeded") }
        if let location { args += ["-CrushlyDemoLocation", location] }
        app.launchArguments = args + extra
        return app
    }
}

extension XCUIApplication {
    /// Any element by accessibility identifier.
    func element(_ id: String) -> XCUIElement { descendants(matching: .any)[id] }

    func text(containing fragment: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    func attach(_ test: XCTestCase, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }

    /// Spaces → "Turn on campus matching" → consent sheet for the simulated space.
    func turnOnAndWaitForConsent(file: StaticString = #filePath, line: UInt = #line) {
        let turnOn = buttons["status.turnOn"]
        XCTAssertTrue(turnOn.waitForExistence(timeout: 8), "Spaces shows the turn-on button", file: file, line: line)
        turnOn.tap()
        // Entry needs two stable fixes ≥ 5 s apart; the simulator emits one every 4 s.
        XCTAssertTrue(staticTexts["consent.title"].waitForExistence(timeout: 20), "consent sheet appears", file: file, line: line)
    }

    func openToMatching(file: StaticString = #filePath, line: UInt = #line) {
        turnOnAndWaitForConsent(file: file, line: line)
        buttons["consent.open"].tap()
        XCTAssertTrue(text(containing: "Open to matching during this visit").waitForExistence(timeout: 8), file: file, line: line)
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
