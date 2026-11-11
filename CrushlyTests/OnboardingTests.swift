import Foundation
import Testing
@testable import Crushly

/// Phase 2: registration, gates, profile completion and session state, driven through AppState
/// exactly as the UI drives it.
@MainActor
struct OnboardingTests {
    private func makeState(seeded: Bool = false) -> AppState {
        let demo = DemoBackend(options: .init(seededAccount: seeded, receiptDelay: 0, latency: .zero))
        return AppState(config: AppConfig(environment: .demo), backend: demo, demo: demo)
    }

    private func completeProfile(_ state: AppState) async throws -> Profile {
        let path = try await state.backend.uploadPhoto(Data([0xFF, 0xD8, 0xFF]))
        var profile = Profile(id: state.userID!)
        profile.firstName = "Avery"
        profile.age = 20
        profile.interests = ["Music", "Coffee", "Film"]
        profile.promptAnswer = "Tacos after midnight."
        profile.photoPaths = [path]
        return profile
    }

    @Test func freshLaunchIsSignedOut() async {
        let state = makeState()
        await state.bootstrap()
        #expect(state.phase == .signedOut)
    }

    @Test func onlyUSCAddressesCanRequestACode() async {
        let state = makeState()
        await #expect(throws: CrushlyError.domainNotAllowed) { try await state.requestCode(email: "someone@gmail.com") }
        await #expect(throws: CrushlyError.domainNotAllowed) { try await state.requestCode(email: "someone@ucla.edu") }
        await #expect(throws: CrushlyError.domainNotAllowed) { try await state.requestCode(email: "someone@cs.usc.edu") }
        try? await state.requestCode(email: "Avery@USC.edu")
    }

    @Test func wrongCodeIsRejected() async throws {
        let state = makeState()
        try await state.requestCode(email: "avery@usc.edu")
        await #expect(throws: CrushlyError.invalidVerificationCode) { try await state.verifyCode(email: "avery@usc.edu", code: "000000") }
        #expect(state.phase != .ready)
    }

    @Test func fullOnboardingReachesReadyAndPersistsAcrossSignOut() async throws {
        let state = makeState()
        await state.bootstrap()
        try await state.requestCode(email: "avery@usc.edu")
        try await state.verifyCode(email: "avery@usc.edu", code: DemoWorld.demoCode)
        #expect(state.phase == .needsTerms)

        try await state.acceptTerms()
        #expect(state.phase == .needsProfile)
        #expect(state.account.ageConfirmed)

        let profile = try await completeProfile(state)
        try await state.saveProfile(profile)
        #expect(state.phase == .ready)
        #expect(state.profile?.firstName == "Avery")
        #expect(state.profile?.photoReviewStatus == .pending)

        // Sign out and back in: the same saved account state comes back.
        await state.signOut()
        #expect(state.phase == .signedOut)
        #expect(state.profile == nil)
        try await state.requestCode(email: "avery@usc.edu")
        try await state.verifyCode(email: "avery@usc.edu", code: DemoWorld.demoCode)
        #expect(state.phase == .ready)
        #expect(state.profile?.firstName == "Avery")
        #expect(state.profile?.interests == ["Music", "Coffee", "Film"])
    }

    @Test func incompleteProfileKeepsUserInOnboarding() async throws {
        let state = makeState()
        try await state.requestCode(email: "avery@usc.edu")
        try await state.verifyCode(email: "avery@usc.edu", code: DemoWorld.demoCode)
        try await state.acceptTerms()

        var profile = try await completeProfile(state)
        profile.photoPaths = []
        #expect(profile.missingFields == ["At least one photo"])
        try await state.saveProfile(profile)
        #expect(state.phase == .needsProfile)

        profile.interests = ["Music"]
        await #expect(throws: CrushlyError.self) { try await state.saveProfile(profile) }

        profile = try await completeProfile(state)
        profile.age = 17
        await #expect(throws: CrushlyError.self) { try await state.saveProfile(profile) }
    }

    @Test func clientCannotGrantItselfServerOnlyStatus() async throws {
        let state = makeState(seeded: true)
        await state.bootstrap()
        var profile = try #require(state.profile)
        profile.photoReviewStatus = .approved
        profile.selfieStatus = .verified
        try await state.saveProfile(profile)
        #expect(state.profile?.photoReviewStatus == .pending)
        #expect(state.profile?.selfieStatus == .notStarted)
    }

    @Test func changingPhotosSendsThemBackToReview() async throws {
        let state = makeState(seeded: true)
        await state.bootstrap()
        await state.demoSimulateReview(.approved)
        #expect(state.profile?.photoReviewStatus == .approved)

        var profile = try #require(state.profile)
        profile.photoPaths.append(try await state.backend.uploadPhoto(Data([1, 2, 3])))
        try await state.saveProfile(profile)
        #expect(state.profile?.photoReviewStatus == .pending)
    }

    @Test func deletingAccountRemovesData() async throws {
        let state = makeState(seeded: true)
        await state.bootstrap()
        #expect(state.phase == .ready)
        try await state.deleteAccount()
        #expect(state.phase == .signedOut)

        try await state.requestCode(email: "tommy@usc.edu")
        try await state.verifyCode(email: "tommy@usc.edu", code: DemoWorld.demoCode)
        #expect(state.phase == .needsTerms)
        #expect(state.profile == nil)
    }

    @Test func emailRuleIsCaseInsensitiveAndExact() {
        let rules = AppRules.default
        #expect(rules.isAllowedEmail("A.B@USC.EDU"))
        #expect(!rules.isAllowedEmail("ab@usc.edu.evil.com"))
        #expect(!rules.isAllowedEmail("@usc.edu"))
        #expect(!rules.isAllowedEmail("no-at-sign"))
    }
}
