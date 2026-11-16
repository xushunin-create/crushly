import Foundation
import Testing
@testable import Crushly

/// Notification routing and the permission moment.
@MainActor
struct NotificationsTests {
    @Test func routesParseStrictly() {
        let id = UUID()
        #expect(NotificationRoute("connections") == .connections)
        #expect(NotificationRoute("match:\(id.uuidString)") == .match(id))
        #expect(NotificationRoute("match:not-a-uuid") == nil)
        #expect(NotificationRoute("profile:\(id.uuidString)") == nil, "no route can open someone's profile directly")
        #expect(NotificationRoute("around") == nil && NotificationRoute("signals") == nil, "removed features")
        #expect(NotificationRoute(nil) == nil)
        #expect(NotificationRoute("") == nil)
    }

    @Test func routeTappedBeforeSignInWaitsForTheAccount() async throws {
        let state = TestWorld.state(TestWorld.demo(seeded: false))
        await state.bootstrap()
        let id = UUID()
        state.open(.match(id))
        #expect(state.pendingRoute == .match(id), "not applied while signed out")
        #expect(state.connectionsPath.isEmpty)

        try await state.requestCode(email: "avery@usc.edu")
        try await state.verifyCode(email: "avery@usc.edu", code: DemoWorld.demoCode)
        try await state.acceptTerms()
        #expect(state.pendingRoute != nil, "still waiting during onboarding")
        var profile = Profile(id: state.userID!)
        profile.firstName = "Avery"; profile.interests = ["Music", "Coffee", "Film"]; profile.promptAnswer = "Tacos."
        profile.photoPaths = [try await state.backend.uploadPhoto(Data([1]))]
        try await state.saveProfile(profile, preferences: MatchPreferences(matchGender: .woman, showMe: [.man]))

        #expect(state.phase == .ready)
        #expect(state.pendingRoute == nil)
        #expect(state.selectedTab == .connections)
        #expect(state.connectionsPath == [id])
    }

    @Test func openingARouteNeverChangesVisibility() async throws {
        let demo = TestWorld.demo()
        let state = TestWorld.state(demo)
        await state.bootstrap()
        state.open(.connections)
        #expect(state.selectedTab == .connections && state.connectionsPath.isEmpty)
        #expect(state.consentPrompt == nil)
        #expect(try await demo.myParticipation().session == nil, "a notification never grants consent")
    }

    @Test func permissionIsOfferedOnlyAfterTheFirstInterest() async throws {
        let state = TestWorld.state(TestWorld.demo())
        await state.bootstrap()
        #expect(!state.shouldOfferNotifications, "never on launch")

        await state.turnOnCampusMatching()
        await state.walkInto(DemoWorld.mcCarthyQuad)
        await state.openToMatching()
        let noah = try #require(state.candidates.first { $0.firstName == "Noah" })
        _ = try await state.expressInterest(in: noah)
        // The simulator's real permission may already be decided; only assert when it isn't.
        if state.notificationPermission == .notDetermined {
            #expect(state.shouldOfferNotifications)
            state.dismissNotificationPrimer()
            #expect(!state.shouldOfferNotifications, "'Not now' is respected")
        }
    }
}
