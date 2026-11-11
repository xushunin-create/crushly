import Foundation
import Testing
@testable import Crushly

/// Phase 7: notification routing and the permission moment.
@MainActor
struct NotificationsTests {
    private func makeState(seeded: Bool) -> AppState {
        UserDefaults.standard.removeObject(forKey: "crushly.notificationPrimerDismissed")
        let demo = DemoBackend(options: .init(seededAccount: seeded, receiptDelay: 0, latency: .zero))
        return AppState(config: AppConfig(environment: .demo), backend: demo, demo: demo)
    }

    @Test func routesParseStrictly() {
        let id = UUID()
        #expect(NotificationRoute("signals") == .signals)
        #expect(NotificationRoute("around") == .around)
        #expect(NotificationRoute("match:\(id.uuidString)") == .match(id))
        #expect(NotificationRoute("match:not-a-uuid") == nil)
        #expect(NotificationRoute("profile:\(id.uuidString)") == nil, "no route can open someone's profile directly")
        #expect(NotificationRoute(nil) == nil)
        #expect(NotificationRoute("") == nil)
    }

    @Test func routeTappedBeforeSignInWaitsForTheAccount() async throws {
        let state = makeState(seeded: false)
        await state.bootstrap()
        let id = UUID()
        state.open(.match(id))
        #expect(state.pendingRoute == .match(id), "not applied while signed out")
        #expect(state.signalsPath.isEmpty)

        try await state.requestCode(email: "avery@usc.edu")
        try await state.verifyCode(email: "avery@usc.edu", code: DemoWorld.demoCode)
        try await state.acceptTerms()
        #expect(state.pendingRoute != nil, "still waiting during onboarding")
        var profile = Profile(id: state.userID!)
        profile.firstName = "Avery"; profile.interests = ["Music", "Coffee", "Film"]; profile.promptAnswer = "Tacos."
        profile.photoPaths = [try await state.backend.uploadPhoto(Data([1]))]
        try await state.saveProfile(profile)

        #expect(state.phase == .ready)
        #expect(state.pendingRoute == nil)
        #expect(state.selectedTab == .signals)
        #expect(state.signalsPath == [id])
    }

    @Test func openingARouteClosesAnyRevealAndPicksTheTab() async {
        let state = makeState(seeded: true)
        await state.bootstrap()
        state.open(.signals)
        #expect(state.selectedTab == .signals && state.signalsPath.isEmpty)
        state.open(.around)
        #expect(state.selectedTab == .around)
    }

    @Test func permissionIsOfferedOnlyAfterTheFirstSignal() async throws {
        let state = makeState(seeded: true)
        await state.bootstrap()
        await state.refreshSocial()
        #expect(!state.shouldOfferNotifications, "never on launch")

        try await state.startPulse(spaceID: DemoWorld.village, durationMinutes: 30, untilEventEnd: false, availability: .either)
        let noah = try #require(state.around.first { $0.firstName == "Noah" })
        _ = try await state.sendHeartSignal(to: noah)
        // The simulator's real permission may already be decided; only assert when it isn't.
        if state.notificationPermission == .notDetermined {
            #expect(state.shouldOfferNotifications)
            state.dismissNotificationPrimer()
            #expect(!state.shouldOfferNotifications, "'Not now' is respected")
        }
    }
}
