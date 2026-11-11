import Foundation
import Testing
@testable import Crushly

/// The demo backend must enforce the same rules as the SQL functions (BACKEND_CONTRACT §3–4),
/// otherwise demo walkthroughs would promise behaviour the server doesn't have.
@MainActor
struct DemoRulesTests {
    private let village = DemoWorld.village
    private func person(_ name: String) -> UUID {
        DemoWorld.people().first { $0.profile.firstName == name }!.profile.id
    }

    private func liveBackend() async throws -> DemoBackend {
        let demo = DemoBackend(options: .init(seededAccount: true, receiptDelay: 0, latency: .zero))
        _ = try await demo.startPulse(spaceID: village, durationMinutes: 30, untilEventEnd: false, availability: .either)
        return demo
    }

    // MARK: Visibility

    @Test func aroundRequiresYourOwnLivePulse() async {
        let demo = DemoBackend(options: .init(seededAccount: true, receiptDelay: 0, latency: .zero))
        await #expect(throws: CrushlyError.noLiveSession) { try await demo.aroundProfiles() }
    }

    @Test func aroundShowsOnlyEligiblePeopleInYourSpace() async throws {
        let demo = try await liveBackend()
        let names = Set(try await demo.aroundProfiles().map(\.firstName))
        #expect(names.isSuperset(of: ["Mina", "Alex", "Jamie", "Noah", "Priya", "Marcus", "Elena"]))
        #expect(!names.contains("Taylor"), "paused users are hidden")
        #expect(!names.contains("Jordan"), "shielded users are hidden")
        #expect(!names.contains("Sam"), "verified-only users are hidden from unapproved viewers")
        #expect(!names.contains("Rio"), "other spaces are not visible")
        #expect(!names.contains("Devon"))
    }

    @Test func verifiedOnlyUserAppearsAfterApproval() async throws {
        let demo = try await liveBackend()
        demo.simulatePhotoReview(.approved)
        #expect(try await demo.aroundProfiles().contains { $0.firstName == "Sam" })
    }

    @Test func pauseHidesAndExpiryBlocksResume() async throws {
        let demo = try await liveBackend()
        _ = try await demo.pausePulse()
        await #expect(throws: CrushlyError.noLiveSession) { try await demo.aroundProfiles() }
        _ = try await demo.resumePulse()
        #expect(try await !demo.aroundProfiles().isEmpty)

        _ = try await demo.pausePulse()
        demo.skipAhead(minutes: 31)
        await #expect(throws: CrushlyError.sessionExpired) { try await demo.resumePulse() }
        let account = try await demo.loadAccount()
        #expect(account.pulse == nil, "expired sessions are not returned as live")
    }

    @Test func durationsAreValidated() async throws {
        let demo = DemoBackend(options: .init(seededAccount: true, receiptDelay: 0, latency: .zero))
        await #expect(throws: CrushlyError.invalidDuration) {
            try await demo.startPulse(spaceID: village, durationMinutes: 45, untilEventEnd: false, availability: .either)
        }
        await #expect(throws: CrushlyError.invalidDuration) {
            try await demo.startPulse(spaceID: village, durationMinutes: nil, untilEventEnd: true, availability: .either)
        }
        let session = try await demo.startPulse(spaceID: DemoWorld.hackathon, durationMinutes: nil, untilEventEnd: true, availability: .meetNow)
        let space = try await demo.spaces().first { $0.id == DemoWorld.hackathon }
        #expect(session.expiresAt == space?.endsAt)
    }

    // MARK: Signals

    @Test func signalLimitDuplicatesAndSelf() async throws {
        let demo = try await liveBackend()
        _ = try await demo.aroundProfiles()
        await #expect(throws: CrushlyError.selfSignal) {
            try await demo.sendHeartSignal(to: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!)
        }

        let first = try await demo.sendHeartSignal(to: person("Noah"))
        #expect(first == .sent(remaining: 4))
        await #expect(throws: CrushlyError.alreadySignaled) { try await demo.sendHeartSignal(to: person("Noah")) }

        for name in ["Priya", "Marcus", "Elena", "Jamie"] { _ = try await demo.sendHeartSignal(to: person(name)) }
        await #expect(throws: CrushlyError.limitReached) { try await demo.sendHeartSignal(to: person("Alex")) }
    }

    @Test func cannotSignalSomeoneYouCannotSee() async throws {
        let demo = try await liveBackend()
        await #expect(throws: CrushlyError.notAvailable) { try await demo.sendHeartSignal(to: person("Rio")) }
        await #expect(throws: CrushlyError.notAvailable) { try await demo.sendHeartSignal(to: person("Jordan")) }
    }

    @Test func receiptsAreAnonymousAndCoarse() async throws {
        let demo = try await liveBackend()
        let receipts = try await demo.receipts()
        #expect(receipts.count == 1, "Mina's scripted signal")
        let receipt = try #require(receipts.first)
        let seconds = receipt.receivedBucket.timeIntervalSince1970
        #expect(seconds.truncatingRemainder(dividingBy: 900) == 0, "time is rounded to 15-minute buckets")
        // SignalReceipt has no sender field by construction; make sure nothing else leaks it either.
        let mirror = Mirror(reflecting: receipt).children.compactMap(\.label)
        #expect(Set(mirror) == ["id", "receivedBucket", "spaceName"])
    }

    // MARK: Matching

    @Test func reciprocalSignalCreatesExactlyOneHeartSync() async throws {
        let demo = try await liveBackend()
        _ = try await demo.aroundProfiles()
        let result = try await demo.sendHeartSignal(to: person("Mina"))
        guard case .matched = result else { Issue.record("expected a match, got \(result)"); return }
        let matches = try await demo.matches()
        #expect(matches.count == 1)
        #expect(matches.first?.kind == .heartSync)
        #expect(matches.first?.connection.status == .pendingConfirmation)
        #expect(try await demo.receipts().isEmpty, "a matched receipt no longer shows as anonymous")
        await #expect(throws: CrushlyError.alreadyMatched) { try await demo.sendHeartSignal(to: person("Mina")) }
    }

    @Test func delayedReplyBecomesAHeartSync() async throws {
        let demo = try await liveBackend()
        _ = try await demo.aroundProfiles()
        #expect(try await demo.sendHeartSignal(to: person("Alex")) == .sent(remaining: 4))
        #expect(try await demo.matches().isEmpty)
        demo.skipAhead(minutes: 1)
        let matches = try await demo.matches()
        #expect(matches.map(\.other.firstName) == ["Alex"])
        #expect(matches.first?.kind == .heartSync)
    }

    @Test func signallingAfterTheyLeftIsCrossedHearts() async throws {
        let demo = try await liveBackend()
        _ = try await demo.aroundProfiles()          // records the encounter with Jamie
        demo.skipAhead(minutes: 4)                   // Jamie signals at 30 s, leaves at 3 min
        #expect(try await !demo.aroundProfiles().contains { $0.firstName == "Jamie" })
        #expect(try await demo.recentEncounters().contains { $0.firstName == "Jamie" })
        let result = try await demo.sendHeartSignal(to: person("Jamie"))
        guard case .matched = result else { Issue.record("expected a match, got \(result)"); return }
        #expect(try await demo.matches().first?.kind == .crossedHearts)
    }

    @Test func connectionsExpireWithoutConfirmation() async throws {
        let demo = try await liveBackend()
        _ = try await demo.aroundProfiles()
        _ = try await demo.sendHeartSignal(to: person("Mina"))
        demo.skipAhead(minutes: 25 * 60)
        #expect(try await demo.matches().first?.connection.status == .expired)
    }

    // MARK: Safety

    @Test func blockingHidesInBothDirectionsAndWithdrawsSignals() async throws {
        let demo = try await liveBackend()
        #expect(try await demo.receipts().count == 1)
        try await demo.block(userID: person("Mina"))
        #expect(try await !demo.aroundProfiles().contains { $0.firstName == "Mina" })
        #expect(try await demo.receipts().isEmpty)
        await #expect(throws: CrushlyError.notAvailable) { try await demo.sendHeartSignal(to: person("Mina")) }
        try await demo.unblock(userID: person("Mina"))
        #expect(try await demo.aroundProfiles().contains { $0.firstName == "Mina" })
        #expect(try await demo.receipts().isEmpty, "withdrawn signals don't come back after unblocking")
    }

    @Test func shieldEndsSessionAndExitDoesNotRestartIt() async throws {
        let demo = try await liveBackend()
        _ = try await demo.enterShield(durationMinutes: 60)
        #expect(try await demo.loadAccount().pulse == nil)
        await #expect(throws: CrushlyError.shielded) {
            try await demo.startPulse(spaceID: village, durationMinutes: 30, untilEventEnd: false, availability: .either)
        }
        try await demo.exitShield()
        let account = try await demo.loadAccount()
        #expect(account.shield == nil)
        #expect(account.pulse == nil, "leaving Shield never makes you visible again on its own")
    }
}
