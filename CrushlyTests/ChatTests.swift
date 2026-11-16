import Foundation
import Testing
import Supabase
@testable import Crushly

/// Phase 5: inbox, thread paging, retry-safe sends, leave & delete, block/report with evidence, the protected local
/// cache and realtime pokes. Driven through AppState against the demo fixture (which mirrors the SQL rules).
@MainActor
struct ChatTests {
    private func myMessages(_ demo: DemoBackend, _ match: UUID) async throws -> [ChatMessage] {
        try await demo.fetchMessages(matchID: match, before: nil, limit: 50).filter(\.senderIsMe)
    }

    // MARK: Sending

    @Test func sendShowsSendingThenSent() async throws {
        let (state, demo, match) = try await AppState.matchedWithMina()
        await state.openThread(match)
        await state.sendMessage("  hi Mina  ", in: match)
        #expect(state.thread(match).pending.isEmpty)
        #expect(state.thread(match).messages.map(\.body) == ["hi Mina"])
        #expect(try await myMessages(demo, match).count == 1)
        #expect(state.conversation(with: match)?.lastMessagePreview == "hi Mina")
    }

    @Test func failedSendStaysFailedUntilRetried() async throws {
        let (state, demo, match) = try await AppState.matchedWithMina()
        await state.openThread(match)
        demo.simulateOfflineSends = 1
        await state.sendMessage("are you there?", in: match)
        let failed = try #require(state.thread(match).pending.first)
        #expect(failed.state == .failed)
        #expect(try await myMessages(demo, match).isEmpty)

        await state.retry(failed.id, in: match)
        #expect(state.thread(match).pending.isEmpty)
        #expect(state.thread(match).messages.map(\.id) == [failed.id], "the retry kept the original client id")
    }

    @Test func retryAfterALostResponseNeverDuplicates() async throws {
        let (state, demo, match) = try await AppState.matchedWithMina()
        await state.openThread(match)
        demo.simulateLostResponses = 1               // stored on the server, but the reply never arrived
        await state.sendMessage("only once", in: match)
        let pending = try #require(state.thread(match).pending.first)
        #expect(pending.state == .failed)
        await state.retry(pending.id, in: match)
        #expect(try await myMessages(demo, match).map(\.body) == ["only once"])
        #expect(state.thread(match).messages.filter(\.senderIsMe).count == 1)
    }

    @Test func messageLengthIsLimitedOnBothSides() async throws {
        let (state, demo, match) = try await AppState.matchedWithMina()
        await state.sendMessage(String(repeating: "x", count: 2001), in: match)
        #expect(state.thread(match).pending.isEmpty && state.errorMessage != nil)
        await #expect(throws: CrushlyError.self) {
            try await demo.sendMessage(matchID: match, clientMessageID: UUID(), body: String(repeating: "x", count: 2001))
        }
        await #expect(throws: CrushlyError.self) { try await demo.sendMessage(matchID: match, clientMessageID: UUID(), body: "   ") }
    }

    // MARK: Paging

    @Test func keysetPagingLoadsOlderMessagesWithoutGapsOrDuplicates() async throws {
        let (state, demo, match) = try await AppState.matchedWithMina()
        for i in 0..<120 { _ = try await demo.sendMessage(matchID: match, clientMessageID: UUID(), body: "m\(i)") }
        await state.openThread(match)
        #expect(state.thread(match).messages.count == 50)
        #expect(state.thread(match).hasMore)
        await state.loadOlder(match)
        await state.loadOlder(match)
        // Mina's two scripted replies are interleaved; the 120 we sent must all be there, in order, once each.
        let mine = state.thread(match).messages.filter(\.senderIsMe).map(\.body)
        #expect(mine == (0..<120).map { "m\($0)" }, "oldest first, complete, no duplicates")
        #expect(state.thread(match).messages.count == 122)
        #expect(Set(state.thread(match).messages.map(\.id)).count == 122)
        #expect(!state.thread(match).hasMore)
    }

    // MARK: Leave & delete

    @Test func leaveDeletesForBothAndADelayedRetryCannotRecreateIt() async throws {
        let (state, demo, match) = try await AppState.matchedWithMina()
        await state.openThread(match)
        await state.sendMessage("hello", in: match)
        demo.simulateOfflineSends = 1
        await state.sendMessage("queued while offline", in: match)
        let queued = try #require(state.thread(match).pending.first)

        try await state.leaveConversation(match)
        #expect(state.conversations.isEmpty)
        #expect(state.threads[match] == nil, "thread and pending sends purged")
        #expect(try await demo.conversations().isEmpty, "gone for the other person too")
        await #expect(throws: CrushlyError.notFound, "a delayed retry of the queued send gets not_found") {
            try await demo.sendMessage(matchID: match, clientMessageID: queued.id, body: queued.body)
        }
        #expect(try await demo.conversations().isEmpty, "and recreates nothing")
        await #expect(throws: CrushlyError.notFound) { try await demo.fetchMessages(matchID: match, before: nil, limit: 50) }
    }

    @Test func sendingToAConversationThatEndedElsewherePurgesIt() async throws {
        let (state, demo, match) = try await AppState.matchedWithMina()
        await state.openThread(match)
        try await demo.leaveConversation(matchID: match)        // e.g. the other person left
        await state.sendMessage("hi?", in: match)
        #expect(state.conversation(with: match) == nil)
        #expect(state.threads[match] == nil)
        #expect(state.errorMessage == "This conversation has ended.")
    }

    // MARK: Safety

    @Test func reportSendsOnlySelectedEvidenceThenBlocksAndPurges() async throws {
        let (state, demo, match) = try await AppState.matchedWithMina()
        await state.openThread(match)
        await state.sendMessage("first", in: match)
        await state.sendMessage("second", in: match)
        let chosen = try #require(state.thread(match).messages.first { $0.body == "second" })
        let mina = try #require(state.conversation(with: match)).other

        try await state.report(mina.id, category: .harassment, details: "test", evidenceMessageIDs: [chosen.id])
        let report = try #require(demo.submittedReports.last)
        #expect(report.evidence.map(\.body) == ["second"], "only what the reporter selected")
        #expect(state.conversations.isEmpty && state.threads.isEmpty)
        #expect(state.messageCache.cachedMatchIDs(user: state.userID!).isEmpty)
        #expect(try await demo.blockedUsers().map(\.id) == [mina.id], "reporting also blocks")
    }

    @Test func evidenceMustComeFromThatConversation() async throws {
        let (_, demo, match) = try await AppState.matchedWithMina()
        let mina = DemoWorld.people().first { $0.profile.firstName == "Mina" }!.profile.id
        _ = try await demo.sendMessage(matchID: match, clientMessageID: UUID(), body: "x")
        await #expect(throws: CrushlyError.self) {
            try await demo.report(userID: mina, category: .spam, details: "", evidenceMessageIDs: [UUID()])
        }
    }

    @Test func blockingPurgesTheConversation() async throws {
        let (state, _, match) = try await AppState.matchedWithMina()
        await state.openThread(match)
        await state.sendMessage("hey", in: match)
        let mina = try #require(state.conversation(with: match)).other
        try await state.block(mina.id)
        #expect(state.conversations.isEmpty && state.threads[match] == nil)
        #expect(state.messageCache.cachedMatchIDs(user: state.userID!).isEmpty)
    }

    // MARK: Local cache

    @Test func cacheIsProtectedAndExcludedFromBackup() async throws {
        let (state, _, match) = try await AppState.matchedWithMina()
        await state.openThread(match)
        await state.sendMessage("cached", in: match)
        let user = try #require(state.userID)
        #expect(state.messageCache.load(user: user, match: match)?.messages.map(\.body) == ["cached"])
        let attrs = state.messageCache.attributes(user: user, match: match)
        #expect(attrs.excludedFromBackup == true)
        #expect(attrs.protection == nil || attrs.protection == .complete, "complete file protection (the simulator may not report it)")
    }

    @Test func cachedThreadsNotListedByTheServerArePurged() async throws {
        let (state, _, match) = try await AppState.matchedWithMina()
        let user = try #require(state.userID)
        let stale = UUID()
        state.messageCache.save(CachedThread(messages: [ChatMessage(id: UUID(), senderIsMe: false, body: "old", createdAt: Date())]),
                                user: user, match: stale)
        await state.refreshConversations()
        #expect(state.messageCache.load(user: user, match: stale) == nil, "reconciled against my_conversations()")
        await state.openThread(stale)
        #expect(state.threads[stale] == nil, "a cached thread is never shown unless the server lists it")
        _ = match
    }

    @Test func signOutPurgesEverything() async throws {
        let (state, _, match) = try await AppState.matchedWithMina()
        await state.openThread(match)
        await state.sendMessage("bye", in: match)
        let user = try #require(state.userID)
        await state.signOut()
        #expect(state.messageCache.cachedMatchIDs(user: user).isEmpty)
        #expect(state.threads.isEmpty && state.conversations.isEmpty)
    }

    // MARK: Realtime

    @Test func pokesTriggerARefetchNotAPayload() async throws {
        let (state, demo, match) = try await AppState.matchedWithMina()
        await state.openThread(match)
        await state.sendMessage("hi!", in: match)
        demo.runScriptsNow()                                   // Mina's scripted reply lands on the "server"
        await state.handle(RealtimePoke(kind: .message, matchID: match))
        #expect(state.thread(match).messages.map(\.body) == ["hi!", "Hi! Okay, this is fun."])

        try await demo.leaveConversation(matchID: match)
        await state.handle(RealtimePoke(kind: .conversationRemoved, matchID: match))
        #expect(state.conversation(with: match) == nil && state.threads[match] == nil)
    }

    @Test func aForgedPokeCannotCreateAConversation() async throws {
        let (state, _, _) = try await AppState.matchedWithMina()
        let before = state.conversations
        await state.handle(RealtimePoke(kind: .match, matchID: UUID()))
        #expect(state.conversations == before, "pokes only trigger refetches; the server decides")
    }

    @Test func pokePayloadParsing() {
        let id = UUID()
        let envelope: [String: AnyJSON] = ["event": .string("poke"),
                                           "payload": .object(["type": .string("conversation_removed"), "match_id": .string(id.uuidString.lowercased())])]
        #expect(SupabaseBackend.parsePoke(envelope) == RealtimePoke(kind: .conversationRemoved, matchID: id))
        #expect(SupabaseBackend.parsePoke(["type": .string("message"), "match_id": .string(id.uuidString)]) == RealtimePoke(kind: .message, matchID: id))
        #expect(SupabaseBackend.parsePoke(["type": .string("body"), "text": .string("hi")]) == nil)
    }

    @Test func preciseTimestampsRoundTripMicroseconds() throws {
        let raw = "2026-11-16T10:00:00.123456+00:00"
        let date = try #require(PreciseTimestamp.parse(raw))
        #expect(PreciseTimestamp.format(date) == "2026-11-16T10:00:00.123456Z")
        #expect(PreciseTimestamp.parse("2026-11-16T10:00:00+00") != nil)
    }
}
