import Foundation
import Testing
@testable import Crushly

/// Phase 5: connection lifecycle, Connect Later actions and the consent-based Find Each Other flow.
@MainActor
struct ConnectionsTests {
    private func person(_ name: String) -> UUID {
        DemoWorld.people().first { $0.profile.firstName == name }!.profile.id
    }

    /// Seeded, live in USC Village, with a fresh Heart Sync with Mina.
    private func matchedWithMina() async throws -> (DemoBackend, Match) {
        let demo = DemoBackend(options: .init(seededAccount: true, receiptDelay: 0, latency: .zero))
        _ = try await demo.startPulse(spaceID: DemoWorld.village, durationMinutes: 60, untilEventEnd: false, availability: .either)
        _ = try await demo.aroundProfiles()
        _ = try await demo.sendHeartSignal(to: person("Mina"))
        let match = try #require(try await demo.matches().first)
        return (demo, match)
    }

    private func reload(_ demo: DemoBackend, _ id: UUID) async throws -> Match {
        try #require(try await demo.matches().first { $0.id == id })
    }

    @Test func choosingAStatusConfirmsAndStartsTheInactivityClock() async throws {
        let (demo, match) = try await matchedWithMina()
        #expect(match.connection.status == .pendingConfirmation)
        try await demo.setConnectionStatus(matchID: match.id, status: .findLater)
        let updated = try await reload(demo, match.id)
        #expect(updated.connection.status == .findLater)
        #expect(updated.connection.confirmedAt != nil)
        let days = (updated.connection.activeUntil ?? .distantPast).timeIntervalSince(demo.now()) / 86400
        #expect(abs(days - 7) < 0.01)
    }

    @Test func confirmedButInactiveConnectionsExpire() async throws {
        let (demo, match) = try await matchedWithMina()
        try await demo.setConnectionStatus(matchID: match.id, status: .findLater)
        demo.skipAhead(minutes: 6 * 24 * 60)
        #expect(try await reload(demo, match.id).connection.status == .findLater)
        demo.skipAhead(minutes: 2 * 24 * 60)
        #expect(try await reload(demo, match.id).connection.status == .expired)
        await #expect(throws: CrushlyError.requestExpired) {
            try await demo.sendConnectionAction(matchID: match.id, kind: .coffee, detail: nil)
        }
        try await demo.setConnectionStatus(matchID: match.id, status: .removed)
        #expect(try await reload(demo, match.id).connection.status == .removed)
    }

    @Test func actionsNeedAnAnswerAndOnlyOnePendingPerKind() async throws {
        let (demo, match) = try await matchedWithMina()
        try await demo.sendConnectionAction(matchID: match.id, kind: .coffee, detail: nil)
        await #expect(throws: CrushlyError.self) { try await demo.sendConnectionAction(matchID: match.id, kind: .coffee, detail: nil) }
        #expect(try await reload(demo, match.id).connection.status == .findLater, "sending an action confirms")
        demo.skipAhead(minutes: 0.1)
        #expect(try await reload(demo, match.id).actions.first?.status == .accepted)
    }

    @Test func instagramIsSharedOnlyAfterMutualConsent() async throws {
        let (demo, match) = try await matchedWithMina()
        #expect(try await demo.instagramHandle(matchID: match.id) == nil)
        try await demo.sendConnectionAction(matchID: match.id, kind: .instagramExchange, detail: nil)
        #expect(try await demo.instagramHandle(matchID: match.id) == nil, "a request alone shares nothing")
        demo.skipAhead(minutes: 0.1)
        #expect(try await demo.instagramHandle(matchID: match.id) == "@mina.makes.playlists")
    }

    @Test func incomingSuggestionCanBeAcceptedOrDeclined() async throws {
        let demo = DemoBackend(options: .init(seededAccount: true, receiptDelay: 0, latency: .zero))
        _ = try await demo.startPulse(spaceID: DemoWorld.village, durationMinutes: 60, untilEventEnd: false, availability: .either)
        _ = try await demo.aroundProfiles()
        demo.skipAhead(minutes: 4)
        _ = try await demo.sendHeartSignal(to: person("Jamie"))   // Crossed Hearts
        demo.skipAhead(minutes: 0.2)
        let match = try #require(try await demo.matches().first)
        #expect(match.kind == .crossedHearts)
        let incoming = try #require(match.actions.first { $0.actorID == person("Jamie") })
        #expect(incoming.kind == .coffee && incoming.status == .pending)
        try await demo.respondConnectionAction(actionID: incoming.id, accept: true)
        #expect(try await reload(demo, match.id).actions.first?.status == .accepted)
        await #expect(throws: CrushlyError.notPermitted) { try await demo.respondConnectionAction(actionID: incoming.id, accept: false) }
    }

    @Test func findRequiresBothToAcceptAndCanComplete() async throws {
        let (demo, match) = try await matchedWithMina()
        try await demo.requestFind(matchID: match.id, meetingPoint: "Tommy Trojan")
        var find = try #require(try await reload(demo, match.id).openFind)
        #expect(find.status == .pending, "nothing happens until the other person accepts")
        #expect(find.activeUntil == nil)
        demo.skipAhead(minutes: 0.1)
        find = try #require(try await reload(demo, match.id).openFind)
        #expect(find.status == .accepted)
        try await demo.completeFind(requestID: find.id)
        let updated = try await reload(demo, match.id)
        #expect(updated.openFind?.status == .completed)
        #expect(updated.connection.status == .metTonight)
    }

    @Test func turningOffPulseEndsAnOpenMeetup() async throws {
        let (demo, match) = try await matchedWithMina()
        try await demo.requestFind(matchID: match.id, meetingPoint: "Tommy Trojan")
        demo.skipAhead(minutes: 0.1)
        #expect(try await reload(demo, match.id).openFind?.status == .accepted)
        try await demo.endPulse()
        #expect(try await reload(demo, match.id).openFind?.status == .cancelled)
    }

    @Test func otherPersonLeavingEndsTheMeetup() async throws {
        let demo = DemoBackend(options: .init(seededAccount: true, receiptDelay: 0, latency: .zero))
        _ = try await demo.startPulse(spaceID: DemoWorld.village, durationMinutes: 60, untilEventEnd: false, availability: .either)
        _ = try await demo.aroundProfiles()
        _ = try await demo.sendHeartSignal(to: person("Alex"))
        demo.skipAhead(minutes: 0.5)                       // Alex signals back → match…
        demo.skipAhead(minutes: 0.2)                       // …then asks to meet 6 s later
        let match = try #require(try await demo.matches().first)
        let incoming = try #require(match.openFind)
        #expect(incoming.requesterID == person("Alex") && incoming.status == .pending)
        try await demo.respondFind(requestID: incoming.id, accept: true)
        #expect(try await reload(demo, match.id).openFind?.status == .accepted)
        demo.skipAhead(minutes: 91)                        // Alex's session ends (and so does ours)
        #expect(try await reload(demo, match.id).openFind?.status != .accepted)
    }

    @Test func unansweredMeetRequestTimesOut() async throws {
        let demo = DemoBackend(options: .init(seededAccount: true, receiptDelay: 0, latency: .zero))
        _ = try await demo.startPulse(spaceID: DemoWorld.village, durationMinutes: 60, untilEventEnd: false, availability: .either)
        _ = try await demo.aroundProfiles()
        _ = try await demo.sendHeartSignal(to: person("Alex"))
        demo.skipAhead(minutes: 0.5)
        demo.skipAhead(minutes: 0.2)
        let match = try #require(try await demo.matches().first)
        let request = try #require(match.openFind)
        demo.skipAhead(minutes: 11)
        #expect(try await reload(demo, match.id).openFind?.status == .timedOut)
        await #expect(throws: CrushlyError.self) { try await demo.respondFind(requestID: request.id, accept: true) }
    }

    @Test func shieldAndBlockCancelMeetups() async throws {
        let (demo, match) = try await matchedWithMina()
        try await demo.requestFind(matchID: match.id, meetingPoint: "Tommy Trojan")
        _ = try await demo.enterShield(durationMinutes: 60)
        #expect(try await reload(demo, match.id).openFind?.status == .cancelled)

        let (demo2, match2) = try await matchedWithMina()
        try await demo2.requestFind(matchID: match2.id, meetingPoint: "Tommy Trojan")
        try await demo2.block(userID: person("Mina"))
        #expect(try await demo2.matches().isEmpty, "blocked connections disappear entirely")
    }
}
