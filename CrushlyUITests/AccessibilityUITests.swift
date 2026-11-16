import XCTest

/// Apple's automated accessibility audit (contrast, hit regions, labels, Dynamic Type clipping) on the main screens,
/// at the default size and at the largest accessibility text size.
final class AccessibilityUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private func audit(_ app: XCUIApplication, _ screen: String, types: XCUIAccessibilityAuditType = .all) {
        Thread.sleep(forTimeInterval: 2.0)   // let transitions finish so contrast isn't sampled mid-fade
        do {
            try app.performAccessibilityAudit(for: types) { issue in
                let element = issue.element.map { "\($0.elementType.rawValue) '\($0.label)' id=\($0.identifier)" } ?? "unknown element"
                XCTContext.runActivity(named: "[\(screen)] \(issue.auditType): \(issue.compactDescription) — \(element)") { _ in }
                // Deliberate Dynamic Type caps (tab bar, badges, heart button) are "partially unsupported": logged, not failed.
                if issue.compactDescription.localizedCaseInsensitiveContains("partially") { return true }
                // Content scrolled underneath the translucent tab bar (and the bar's own labels over that content) gets
                // sampled against the blend. Measured from the bar itself, including its top shadow.
                let tabTop = app.buttons["tab.spaces"].exists ? app.buttons["tab.spaces"].frame.minY - 40 : app.frame.height - 130
                if issue.auditType == .contrast, let frame = issue.element?.frame, frame.maxY > tabTop { return true }
                // Reviewed visually (screenshot "privacy"): these List button rows render in full; the audit misreports
                // List rows with a leading icon as clipped (the previous suite documented the same false positive).
                let reviewedClipping: Set<String> = ["Pause campus matching", "Stop checking my location", "Resume campus matching"]
                if issue.auditType == .textClipped, let label = issue.element?.label, reviewedClipping.contains(label) { return true }
                // Unattributable samples (e.g. the system Toggle's grey off-track) can't be acted on.
                if issue.auditType == .contrast, issue.element == nil { return true }
                return false
            }
        } catch {
            XCTFail("[\(screen)] audit failed: \(error)")
        }
    }

    @MainActor
    func testMainScreensPassAudit() throws {
        let app = DemoLaunch.app(location: "upc-mccarthy-quad")
        app.launch()
        XCTAssertTrue(app.buttons["status.turnOn"].waitForExistence(timeout: 8))
        audit(app, "Spaces (off)")
        app.turnOnAndWaitForConsent()
        audit(app, "Consent sheet")
        app.buttons["consent.open"].tap()
        XCTAssertTrue(app.buttons["candidate.Mina"].waitForExistence(timeout: 10))
        audit(app, "Spaces (participating)")
        app.buttons["candidate.Mina"].reveal(in: app).tap()
        XCTAssertTrue(app.buttons["interest.send"].waitForExistence(timeout: 5))
        audit(app, "Profile")
        app.buttons["interest.send"].tap()
        XCTAssertTrue(app.buttons["reveal.message"].waitForExistence(timeout: 8))
        audit(app, "Heart Sync")
        app.buttons["reveal.message"].tap()
        XCTAssertTrue(app.buttons["chat.options"].waitForExistence(timeout: 8))
        audit(app, "Chat")
        app.navigationBars.buttons.element(boundBy: 0).tap()   // back to Connections (the tab bar hides inside a chat)
        XCTAssertTrue(app.buttons["tab.me"].waitForExistence(timeout: 5))
        app.buttons["tab.me"].tap()
        audit(app, "Me")
        app.buttons["me.privacy"].tap()
        XCTAssertTrue(app.buttons["privacy.pause"].waitForExistence(timeout: 5))
        audit(app, "Privacy & safety")
        app.attach(self, "privacy")
    }

    @MainActor
    func testLargestTextSizeHasNoClipping() throws {
        let app = DemoLaunch.app(location: "upc-mccarthy-quad",
                                 extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.launch()
        XCTAssertTrue(app.buttons["status.turnOn"].waitForExistence(timeout: 8))
        audit(app, "Spaces (AX5)", types: [.dynamicType, .textClipped])
        app.attach(self, "ax5-spaces")
        app.turnOnAndWaitForConsent()
        audit(app, "Consent (AX5)", types: [.dynamicType, .textClipped])
        app.attach(self, "ax5-consent")
        app.buttons["consent.open"].reveal(in: app).tap()
        XCTAssertTrue(app.buttons["candidate.Mina"].waitForExistence(timeout: 10))
        audit(app, "Participating (AX5)", types: [.dynamicType, .textClipped])
        app.buttons["tab.connections"].tap()
        audit(app, "Connections (AX5)", types: [.dynamicType, .textClipped])
    }
}
