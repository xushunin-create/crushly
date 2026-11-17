import Foundation
import Testing
@testable import Crushly

/// Phase 4: location → consent → open / renew / revoke, driven through AppState as the app drives it, against the
/// demo fixture (which mirrors the SQL rules).
@MainActor
struct ParticipationFlowTests {
    private let quad = DemoWorld.mcCarthyQuad

    private func readyState(_ given: DemoBackend? = nil) async -> (AppState, DemoBackend, TestLocationProvider) {
        let demo = given ?? TestWorld.demo()
        let location = TestLocationProvider()
        let state = TestWorld.state(demo, location: location)
        await state.bootstrap()
        await state.turnOnCampusMatching()
        return (state, demo, location)
    }

    private func participating() async -> (AppState, DemoBackend, TestLocationProvider) {
        let (state, demo, location) = await readyState()
        await state.walkInto(quad)
        await state.openToMatching()
        return (state, demo, location)
    }

    // MARK: Consent

    @Test func nothingHappensUntilCampusMatchingIsTurnedOn() async {
        let demo = TestWorld.demo()
        let location = TestLocationProvider()
        let state = TestWorld.state(demo, location: location)
        await state.bootstrap()
        #expect(state.spacesStatus == .off)
        #expect(!location.updating, "location is never used before the user turns campus matching on")
        await state.turnOnCampusMatching()
        #expect(location.updating)
        #expect(state.spacesStatus == .outside)
    }

    @Test func stableEntryAsksForConsentAndDismissingMeansInvisible() async throws {
        let (state, demo, _) = await readyState()
        await state.ingest(.sample(TestWorld.sample(quad)))
        #expect(state.consentPrompt == nil, "one fix is not enough")
        await state.ingest(.sample(TestWorld.sample(quad, secondsAgo: -0.001)))
        #expect(state.consentPrompt == nil, "fixes must be ≥ 5 s apart")

        let state2 = (await readyState(demo)).0
        await state2.walkInto(quad)
        let prompt = try #require(state2.consentPrompt)
        #expect(prompt.spaceName == "McCarthy Quad")
        #expect(state2.spacesStatus == .awaitingChoice(spaceName: "McCarthy Quad"))
        #expect(try await demo.myParticipation().session == nil, "detection alone never contacts the server")

        state2.stayInvisible(visit: prompt.visit)
        #expect(state2.consentPrompt == nil)
        #expect(state2.spacesStatus == .invisibleHere(spaceName: "McCarthy Quad"))
        await state2.ingest(.sample(TestWorld.sample(quad)))
        #expect(state2.consentPrompt == nil, "no re-prompt during the same visit")
        #expect(try await demo.myParticipation().session == nil)
    }

    @Test func openToMatchingOpensALeasedSessionAndShowsEligibleCandidates() async throws {
        let (state, demo, location) = await participating()
        let session = try #require(try await demo.myParticipation().session)
        #expect(session.spaceSlug == quad)
        #expect(state.isParticipating)
        #expect(state.spacesStatus == .participating(spaceName: "McCarthy Quad"))
        #expect(location.backgroundActive, "background renewal starts only once the user opted in")
        let names = Set(state.candidates.map(\.firstName))
        #expect(names == ["Mina", "Alex", "Jamie", "Noah", "Priya", "Marcus", "Elena"])
    }

    @Test func renewalsNeedNewerEvidenceAndUseIncreasingSequenceNumbers() async throws {
        let (state, demo, _) = await participating()
        await state.renewIfPossible()
        #expect(state.seq == 0, "no newer fix than the one that opened the session: don't renew")

        await state.ingest(.sample(TestWorld.sample(quad)))
        await state.renewIfPossible()
        #expect(state.seq == 1)
        #expect(try await demo.myParticipation().session?.lastSeq == 1)
        await state.renewIfPossible()
        #expect(state.seq == 1, "the same fix is never cited twice while moving")
        try await Task.sleep(for: .milliseconds(5))
        await state.ingest(.sample(TestWorld.sample(quad)))
        await state.renewIfPossible()
        #expect(state.seq == 2)
        #expect(try await demo.myParticipation().session?.lastSeq == 2)
    }

    @Test func aLapsedLeaseRequiresFreshConfirmation() async throws {
        let (state, demo, location) = await participating()
        // Two minutes without a renewal (e.g. no fresh evidence): the 60 s lease is gone on the server.
        await state.demoSkipAhead(minutes: 2)
        #expect(!state.isParticipating)
        #expect(try await demo.myParticipation().session == nil)
        #expect(!location.backgroundActive)
        #expect(state.consentPrompt != nil, "after the lease lapses, fresh confirmation is required")
    }

    // MARK: Revocation

    @Test func leavingTheSpaceRevokesImmediately() async throws {
        let (state, demo, location) = await participating()
        let epoch = try await demo.myParticipation().consentEpoch
        await state.ingest(.sample(TestWorld.sample(nil)))
        #expect(state.spacesStatus == .outside)
        #expect(try await demo.myParticipation().session == nil)
        #expect(try await demo.myParticipation().consentEpoch == epoch + 1)
        #expect(!location.backgroundActive)
        #expect(state.candidates.isEmpty)
    }

    @Test func goInvisibleRevokesAndDoesNotReprompt() async throws {
        let (state, demo, _) = await participating()
        await state.goInvisible()
        #expect(try await demo.myParticipation().session == nil)
        #expect(state.spacesStatus == .invisibleHere(spaceName: "McCarthy Quad"))
        #expect(state.consentPrompt == nil)
        // Changing your mind during the visit is an explicit new choice.
        await state.ingest(.sample(TestWorld.sample(quad)))
        await state.openToMatching()
        #expect(try await demo.myParticipation().session != nil)
    }

    @Test func losingLocationPermissionRevokes() async throws {
        let (state, demo, location) = await participating()
        location.authorization = .approximate
        await state.ingest(.authorization(.approximate))
        #expect(state.spacesStatus == .needsPermission(.approximateLocation))
        #expect(try await demo.myParticipation().session == nil)
        #expect(!location.updating)
    }

    @Test func pauseRevokesAndResumingNeverOpensASession() async throws {
        let (state, demo, location) = await participating()
        try await state.pauseCampusMatching(minutes: 60)
        #expect(state.spacesStatus == .paused(until: state.participation?.pausedUntil))
        #expect(try await demo.myParticipation().session == nil)
        #expect(!location.updating, "no location use while paused")

        try await state.resumeCampusMatching()
        #expect(try await demo.myParticipation().session == nil)
        #expect(state.consentPrompt == nil)
        #expect(location.updating)
    }

    @Test func signOutRevokesFirst() async throws {
        let (state, demo, location) = await participating()
        await state.signOut()
        #expect(state.phase == .signedOut)
        #expect(!location.updating && !location.backgroundActive)
        try await demo.requestCode(email: "tommy@usc.edu")
        try await demo.verifyCode(email: "tommy@usc.edu", code: DemoWorld.demoCode)
        #expect(try await demo.myParticipation().session == nil)
    }

    @Test func accountDeletionRevokesFirst() async throws {
        let (state, demo, _) = await participating()
        try await state.deleteAccount()
        #expect(state.phase == .signedOut)
        try await demo.requestCode(email: "tommy@usc.edu")
        try await demo.verifyCode(email: "tommy@usc.edu", code: DemoWorld.demoCode)
        #expect(try await demo.myParticipation().session == nil)
    }

    // MARK: Reconciliation

    @Test func launchNeverResumesALeftoverSession() async throws {
        let demo = TestWorld.demo()
        // A previous run of the app opened a session moments ago.
        let epoch = try await demo.myParticipation().consentEpoch
        _ = try await demo.openParticipation(spaceSlug: quad, boundaryVersion: 1, consentEpoch: epoch,
                                             clientRequestID: UUID(), evidence: TestWorld.evidence())
        #expect(try await demo.myParticipation().session != nil)

        let state = TestWorld.state(demo)
        await state.bootstrap()
        #expect(try await demo.myParticipation().session == nil)
        #expect(!state.isParticipating)
    }

    @Test func serverSideExpiryIsNoticedOnForeground() async throws {
        let (state, demo, _) = await participating()
        _ = try await demo.revokeParticipation()     // e.g. revoked from elsewhere
        await state.reconcileParticipation()
        #expect(!state.isParticipating)
        #expect(state.consentPrompt != nil)
    }

    // MARK: Interest and matching

    @Test func receiptsAreAnonymousAndMutualInterestMatches() async throws {
        let (state, _, _) = await participating()
        await state.refreshReceipts()
        #expect(state.interestReceipts == 1, "Mina's scripted interest, as a bare count")

        let mina = try #require(state.candidates.first { $0.firstName == "Mina" })
        let result = try await state.expressInterest(in: mina)
        guard case .matched = result else { Issue.record("expected a match, got \(result)"); return }
        #expect(state.revealMatch?.other.firstName == "Mina")
        #expect(state.conversations.map(\.other.firstName) == ["Mina"])
        #expect(!state.candidates.contains { $0.id == mina.id })
    }

    @Test func interestIsPrivateUntilMutual() async throws {
        let (state, _, _) = await participating()
        let noah = try #require(state.candidates.first { $0.firstName == "Noah" })
        #expect(try await state.expressInterest(in: noah) == .sent(remaining: 4))
        #expect(state.sentInterests.contains(noah.id))
        #expect(state.conversations.isEmpty)
        #expect(state.interestsRemaining == 4)
    }

    // MARK: Environment guard

    @Test func liveModeAlwaysUsesCoreLocation() {
        let live = AppState.make(config: AppConfig(environment: .live(url: URL(string: "https://example.supabase.co")!, anonKey: "anon")))
        #expect(live.location is LocationService)
        #expect(live.simulatedLocation == nil)
        #expect(live.demo == nil)
        let demo = AppState.make(config: AppConfig(environment: .demo))
        #expect(demo.location is SimulatedLocationProvider)
    }

    @Test func simulatedInteriorPointsAreInsideEachZone() {
        let engine = MembershipEngine(zones: TestWorld.zones)
        for zone in TestWorld.zones {
            let verdict = engine.classify(LocationSample(coordinate: TestWorld.point(in: zone.slug), horizontalAccuracy: 8, timestamp: Date()))
            #expect(verdict == .inside(slug: zone.slug, depth: zone.shape.distanceToBoundary(from: TestWorld.point(in: zone.slug))))
        }
    }
}
