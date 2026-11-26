import Foundation
import UIKit
import Testing
@testable import Crushly

/// Phase 2: registration, gates, profile completion and session state, driven through AppState
/// exactly as the UI drives it.
@MainActor
struct OnboardingTests {
    private func makeState(seeded: Bool = false) -> AppState {
        TestWorld.state(TestWorld.demo(seeded: seeded))
    }

    private let prefs = MatchPreferences(matchGender: .woman, showMe: [.man, .nonbinary], ageMin: 19, ageMax: 26)

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
        #expect(state.phase == .needsProfile, "matching preferences are required too")
        try await state.saveProfile(profile, preferences: prefs)
        #expect(state.phase == .ready)
        #expect(state.preferences == prefs)
        #expect(state.profile?.firstName == "Avery")
        #expect(state.profile?.photoReviewStatus == .approved, "screened photos are live right away, no review wait")

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
        try await state.saveProfile(profile, preferences: prefs)
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
        await state.demoSimulateReview(.rejected)
        var profile = try #require(state.profile)
        profile.photoReviewStatus = .approved
        profile.selfieStatus = .verified
        try await state.saveProfile(profile)
        #expect(state.profile?.photoReviewStatus == .rejected, "a moderator's decision can't be overridden by the client")
        #expect(state.profile?.selfieStatus == .notStarted)
    }

    @Test func newPhotosGoLiveImmediately() async throws {
        let state = makeState(seeded: true)
        await state.bootstrap()
        await state.demoSimulateReview(.rejected)

        var profile = try #require(state.profile)
        profile.photoPaths = [try await state.backend.uploadPhoto(Data([1, 2, 3]))]
        try await state.saveProfile(profile)
        #expect(state.profile?.photoReviewStatus == .approved, "replacing a removed photo with a screened one is live at once")
    }

    @Test func explicitPhotosAreRefusedBeforeUpload() async throws {
        let state = makeState(seeded: true)
        await state.bootstrap()
        state.photoSafetyCheck = { _ in .explicit }
        await #expect(throws: CrushlyError.photoRejected) { _ = try await state.uploadPhoto(Data([1, 2, 3])) }
        state.photoSafetyCheck = { _ in throw CrushlyError.unknown("model") }
        await #expect(throws: CrushlyError.photoCheckUnavailable, "a photo that can't be checked is refused") {
            _ = try await state.uploadPhoto(Data([1, 2, 3]))
        }
        state.photoSafetyCheck = { _ in .allowed }
        _ = try await state.uploadPhoto(Data([4, 5, 6]))
    }

    @Test func onDeviceModelLoadsAndAllowsAnOrdinaryImage() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 400)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 100, y: 100, width: 200, height: 200))
        }
        let data = try #require(image.jpegData(compressionQuality: 0.9))
        #expect(PhotoSafetyCheck.isModelAvailable, "the model is bundled and loads")
        #if !targetEnvironment(simulator)
        // The model can only run on a device (Vision's feature print has no Simulator inference context).
        let score = try PhotoSafetyCheck.score(data)
        #expect((0...1).contains(score))
        #endif
        #expect(try await PhotoSafetyCheck.evaluate(data) == .allowed)
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

    @Test func invalidPreferencesAreRejected() async throws {
        let state = makeState(seeded: true)
        await state.bootstrap()
        let profile = try #require(state.profile)
        var bad = prefs
        bad.showMe = []
        await #expect(throws: CrushlyError.self) { try await state.saveProfile(profile, preferences: bad) }
        bad = prefs
        bad.ageMin = 30; bad.ageMax = 25
        await #expect(throws: CrushlyError.self) { try await state.saveProfile(profile, preferences: bad) }
        #expect(!MatchPreferences().isComplete)
        #expect(prefs.isComplete)
    }

    @Test func emailRuleIsCaseInsensitiveAndExact() {
        let rules = AppRules.default
        #expect(rules.isAllowedEmail("A.B@USC.EDU"))
        #expect(!rules.isAllowedEmail("ab@usc.edu.evil.com"))
        #expect(!rules.isAllowedEmail("@usc.edu"))
        #expect(!rules.isAllowedEmail("no-at-sign"))
    }
}
