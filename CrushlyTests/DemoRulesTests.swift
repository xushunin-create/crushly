import Foundation
import Testing
@testable import Crushly

/// The demo fixture must enforce the same rules as the SQL functions (BACKEND_CONTRACT §3–4), otherwise demo
/// walkthroughs would promise behaviour the server doesn't have. Each test names the SQL rule it mirrors.
@MainActor
struct DemoRulesTests {
    private let quad = DemoWorld.mcCarthyQuad

    private func person(_ name: String) -> UUID {
        DemoWorld.people().first { $0.profile.firstName == name }!.profile.id
    }

    private func open(_ demo: DemoBackend, _ slug: String = DemoWorld.mcCarthyQuad) async throws -> ParticipationLease {
        let epoch = try await demo.myParticipation().consentEpoch
        return try await demo.openParticipation(spaceSlug: slug, boundaryVersion: 1, consentEpoch: epoch,
                                                clientRequestID: UUID(), evidence: TestWorld.evidence())
    }

    private func names(_ result: DiscoveryResult) -> Set<String> {
        guard case .candidates(let list) = result else { return [] }
        return Set(list.map(\.firstName))
    }

    // MARK: Participation (open/renew/revoke)

    @Test func openRequiresPlausibleFreshEvidence() async throws {
        let demo = TestWorld.demo()
        let epoch = try await demo.myParticipation().consentEpoch
        func attempt(_ e: LocationEvidence) async throws {
            _ = try await demo.openParticipation(spaceSlug: quad, boundaryVersion: 1, consentEpoch: epoch, clientRequestID: UUID(), evidence: e)
        }
        await #expect(throws: CrushlyError.insufficientAccuracy) { try await attempt(TestWorld.evidence(accuracy: 31)) }
        await #expect(throws: CrushlyError.staleEvidence) { try await attempt(TestWorld.evidence(age: 16)) }
        await #expect(throws: CrushlyError.staleEvidence, "entry needs a moving fix, not a re-cited one") {
            try await attempt(TestWorld.evidence(stationary: true))
        }
        try await attempt(TestWorld.evidence())
    }

    @Test func openChecksSpaceBoundaryAndEpoch() async throws {
        let demo = TestWorld.demo()
        let epoch = try await demo.myParticipation().consentEpoch
        await #expect(throws: CrushlyError.spaceUnavailable) {
            try await demo.openParticipation(spaceSlug: "usc-village-piazza", boundaryVersion: 1, consentEpoch: epoch,
                                             clientRequestID: UUID(), evidence: TestWorld.evidence())
        }
        await #expect(throws: CrushlyError.boundaryOutdated) {
            try await demo.openParticipation(spaceSlug: quad, boundaryVersion: 2, consentEpoch: epoch,
                                             clientRequestID: UUID(), evidence: TestWorld.evidence())
        }
        await #expect(throws: CrushlyError.consentStale, "a delayed 'open' from before a revoke is rejected") {
            _ = try await demo.revokeParticipation()
            _ = try await demo.openParticipation(spaceSlug: quad, boundaryVersion: 1, consentEpoch: epoch,
                                                 clientRequestID: UUID(), evidence: TestWorld.evidence())
        }
    }

    @Test func openIsIdempotentOnTheRequestID() async throws {
        let demo = TestWorld.demo()
        let epoch = try await demo.myParticipation().consentEpoch
        let request = UUID()
        let a = try await demo.openParticipation(spaceSlug: quad, boundaryVersion: 1, consentEpoch: epoch, clientRequestID: request, evidence: TestWorld.evidence())
        let b = try await demo.openParticipation(spaceSlug: quad, boundaryVersion: 1, consentEpoch: epoch, clientRequestID: request, evidence: TestWorld.evidence())
        #expect(a.sessionID == b.sessionID)
    }

    @Test func renewRules() async throws {
        let demo = TestWorld.demo()
        let lease = try await open(demo)
        let fix = TestWorld.evidence(1)
        _ = try await demo.renewParticipation(sessionID: lease.sessionID, seq: 1, evidence: fix)
        await #expect(throws: CrushlyError.staleRequest) {
            try await demo.renewParticipation(sessionID: lease.sessionID, seq: 1, evidence: TestWorld.evidence(2))
        }
        await #expect(throws: CrushlyError.staleEvidence, "a heartbeat citing no newer fix is not evidence") {
            try await demo.renewParticipation(sessionID: lease.sessionID, seq: 2, evidence: fix)
        }
        // While stationary, the last fix may be re-cited (up to 5 min old).
        let stationary = LocationEvidence(fixTimestamp: fix.fixTimestamp, fixAge: 120, horizontalAccuracy: 10, stationary: true)
        _ = try await demo.renewParticipation(sessionID: lease.sessionID, seq: 3, evidence: stationary)

        demo.skipAhead(minutes: 2)
        await #expect(throws: CrushlyError.sessionExpired, "an expired lease can never be revived") {
            try await demo.renewParticipation(sessionID: lease.sessionID, seq: 4, evidence: TestWorld.evidence(3))
        }
    }

    @Test func pauseRejectsOpenAndResumeOpensNothing() async throws {
        let demo = TestWorld.demo()
        _ = try await open(demo)
        await #expect(throws: CrushlyError.invalidDuration) { try await demo.setMatchingPaused(true, minutes: 7) }
        let paused = try await demo.setMatchingPaused(true, minutes: 60)
        #expect(paused.matchingPaused && paused.session == nil)
        await #expect(throws: CrushlyError.matchingPaused) { try await open(demo) }
        let resumed = try await demo.setMatchingPaused(false, minutes: nil)
        #expect(!resumed.matchingPaused && resumed.session == nil)

        _ = try await demo.setMatchingPaused(true, minutes: 60)
        demo.skipAhead(minutes: 61)
        #expect(try await demo.myParticipation().matchingPaused == false, "timed pauses end on their own")
    }

    // MARK: Discovery

    @Test func discoveryRequiresYourOwnSession() async {
        let demo = TestWorld.demo()
        await #expect(throws: CrushlyError.notParticipating) { try await demo.discoverCandidates() }
    }

    @Test func quietSpacesReturnNoCount() async throws {
        let demo = TestWorld.demo()
        _ = try await open(demo, DemoWorld.greatLawn)
        #expect(try await demo.discoverCandidates() == .quiet)
    }

    @Test func eligibilityAppliesBothWays() async throws {
        let demo = TestWorld.demo()
        _ = try await open(demo)
        let visible = names(try await demo.discoverCandidates())
        #expect(visible == ["Mina", "Alex", "Jamie", "Noah", "Priya", "Marcus", "Elena"])
        #expect(!visible.contains("Taylor"), "paused: no session")
        #expect(!visible.contains("Jordan"), "their 'show me' excludes you")
        #expect(!visible.contains("Sam"), "verified-only users are hidden from unapproved viewers")
        #expect(!visible.contains("Rio") && !visible.contains("Devon"), "other spaces are never visible")

        let park = TestWorld.demo()
        _ = try await open(park, DemoWorld.alumniPark)
        #expect(names(try await park.discoverCandidates()) == ["Devon", "Kai"], "Lena's age range excludes you")
    }

    @Test func verifiedOnlyUserAppearsAfterApproval() async throws {
        let demo = TestWorld.demo()
        demo.simulatePhotoReview(.approved)
        _ = try await open(demo)
        #expect(names(try await demo.discoverCandidates()).contains("Sam"))
    }

    @Test func discoveryIsRateLimited() async throws {
        let demo = TestWorld.demo(rateLimits: true)
        _ = try await open(demo)
        _ = try await demo.discoverCandidates()
        await #expect(throws: CrushlyError.rateLimited) { try await demo.discoverCandidates() }
    }

    // MARK: Interest and matching

    @Test func interestOnlyTowardSomeoneYouWereShown() async throws {
        let demo = TestWorld.demo()
        _ = try await open(demo)
        await #expect(throws: CrushlyError.notAvailable, "a known user id can't be probed") {
            try await demo.expressInterest(in: person("Noah"))
        }
        _ = try await demo.discoverCandidates()
        #expect(try await demo.expressInterest(in: person("Noah")) == .sent(remaining: 4))
        await #expect(throws: CrushlyError.alreadySent) { try await demo.expressInterest(in: person("Noah")) }
        await #expect(throws: CrushlyError.notAvailable) { try await demo.expressInterest(in: person("Jordan")) }
        await #expect(throws: CrushlyError.invalidInput("You can't do that.")) { try await demo.expressInterest(in: demo.myID) }
    }

    @Test func fiveInterestsPerVisit() async throws {
        let demo = TestWorld.demo()
        _ = try await open(demo)
        _ = try await demo.discoverCandidates()
        for name in ["Noah", "Priya", "Marcus", "Elena", "Jamie"] { _ = try await demo.expressInterest(in: person(name)) }
        await #expect(throws: CrushlyError.limitReached) { try await demo.expressInterest(in: person("Alex")) }
    }

    @Test func reciprocalInterestMatchesExactlyOnce() async throws {
        let demo = TestWorld.demo()
        _ = try await open(demo)
        _ = try await demo.discoverCandidates()
        #expect(try await demo.interestReceipts() == 1, "Mina, anonymously")
        guard case .matched(let id, _) = try await demo.expressInterest(in: person("Mina")) else {
            Issue.record("expected a match"); return
        }
        #expect(try await demo.conversations().map(\.id) == [id])
        #expect(try await demo.interestReceipts() == 0, "the interest is consumed by the match")
        await #expect(throws: CrushlyError.alreadyMatched) { try await demo.expressInterest(in: person("Mina")) }
    }

    @Test func delayedReciprocationWhileBothAreStillHere() async throws {
        let demo = TestWorld.demo()
        let lease = try await open(demo)
        _ = try await demo.discoverCandidates()
        _ = try await demo.expressInterest(in: person("Alex"))
        #expect(try await demo.conversations().isEmpty)
        demo.skipAhead(minutes: 0.4)    // Alex answers after 20 s; the 60 s lease is still valid
        _ = try await demo.renewParticipation(sessionID: lease.sessionID, seq: 1, evidence: TestWorld.evidence(1))
        #expect(try await demo.conversations().map(\.other.firstName) == ["Alex"])
    }

    @Test func endingASessionDeletesItsInterests() async throws {
        let demo = TestWorld.demo()
        _ = try await open(demo)
        _ = try await demo.discoverCandidates()
        _ = try await demo.expressInterest(in: person("Noah"))
        #expect(try await demo.sentInterests() == [person("Noah")])
        _ = try await demo.revokeParticipation()
        _ = try await open(demo)
        #expect(try await demo.sentInterests().isEmpty, "interests never outlive the visit")
    }

    @Test func someoneLeavingDeletesTheirInterest() async throws {
        let demo = TestWorld.demo()
        let lease = try await open(demo)
        demo.skipAhead(minutes: 0.25)                     // Jamie becomes interested at 10 s
        #expect(try await demo.interestReceipts() == 2, "Mina and Jamie")
        var seq: Int64 = 0
        for _ in 0..<5 {                                   // stay ~3.75 min, renewing within each 60 s lease
            demo.skipAhead(minutes: 0.7)
            seq += 1
            _ = try await demo.renewParticipation(sessionID: lease.sessionID, seq: seq, evidence: TestWorld.evidence(Double(seq)))
        }
        #expect(try await demo.interestReceipts() == 1, "Jamie left; their interest cascaded away")
    }

    // MARK: Safety

    @Test func blockingEndsTheMatchAndInterestsAndUnblockRestoresNothing() async throws {
        let demo = TestWorld.demo()
        _ = try await open(demo)
        _ = try await demo.discoverCandidates()
        _ = try await demo.expressInterest(in: person("Mina"))
        let match = try #require(try await demo.conversations().first)
        try await demo.block(userID: person("Mina"))
        #expect(try await demo.conversations().isEmpty)
        #expect(demo.deletedMatchIDs.contains(match.id))
        #expect(!names(try await demo.discoverCandidates()).contains("Mina"))
        try await demo.unblock(userID: person("Mina"))
        #expect(try await demo.conversations().isEmpty)
    }
}
