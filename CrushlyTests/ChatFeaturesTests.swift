import Foundation
import Testing
@testable import Crushly

/// Replies, reactions, unsend, screenshot notices and bubble grouping. Driven through AppState against the demo
/// fixture, which mirrors supabase/migrations/20261126000000_chat_and_live_photos.sql.
@MainActor
struct ChatFeaturesTests {
    private func send(_ text: String, _ state: AppState, _ match: UUID, replyingTo: ChatMessage? = nil) async throws -> ChatMessage {
        await state.sendMessage(text, in: match, replyingTo: replyingTo)
        return try #require(state.thread(match).messages.last { $0.body == text })
    }

    @Test func replyQuotesTheOriginalAndSurvivesARefetch() async throws {
        let (state, demo, match) = try await AppState.matchedWithMina()
        await state.openThread(match)
        let first = try await send("coffee at 3?", state, match)
        let reply = try await send("or 4 works too", state, match, replyingTo: first)
        #expect(reply.replyTo?.id == first.id)
        #expect(reply.replyTo?.body == "coffee at 3?")

        let fromServer = try await demo.fetchMessages(matchID: match, before: nil, limit: 50)
        #expect(fromServer.first { $0.id == reply.id }?.replyTo?.id == first.id, "the server stores the reply link")
        await #expect(throws: CrushlyError.self) {
            _ = try await demo.sendMessage(matchID: match, clientMessageID: UUID(), body: "x", replyToID: UUID())
        }
    }

    @Test func reactionsToggleLikeTapbacks() async throws {
        let (state, demo, match) = try await AppState.matchedWithMina()
        await state.openThread(match)
        let message = try await send("hi!", state, match)

        func mine() -> [MessageReaction] {
            state.thread(match).messages.first { $0.id == message.id }?.reactions.filter(\.fromMe) ?? []
        }
        await state.toggleReaction("😂", on: message.id, in: match)
        #expect(mine() == [MessageReaction(emoji: "😂", fromMe: true)])
        await state.toggleReaction("❤️", on: message.id, in: match)
        #expect(mine() == [MessageReaction(emoji: "❤️", fromMe: true)], "one reaction per person")
        await state.toggleReaction("❤️", on: message.id, in: match)
        #expect(mine().isEmpty, "picking the same emoji again removes it")
        let stored = try await demo.fetchMessages(matchID: match, before: nil, limit: 50).first { $0.id == message.id }
        #expect(stored?.reactions.contains(where: \.fromMe) == false, "the server agrees")

        await #expect(throws: CrushlyError.self) { try await demo.react(messageID: message.id, emoji: "hello") }
    }

    @Test func theOtherPersonsReactionAndReplyArrive() async throws {
        let (state, demo, match) = try await AppState.matchedWithMina()
        await state.openThread(match)
        let mine = try await send("hey Mina", state, match)
        demo.skipAhead(minutes: 1)
        await state.fetchLatest(match)
        let thread = state.thread(match)
        #expect(thread.messages.first { $0.id == mine.id }?.reactions == [MessageReaction(emoji: "❤️", fromMe: false)])
        #expect(thread.messages.last?.senderIsMe == false)
        #expect(thread.messages.last?.replyTo?.id == mine.id)
    }

    @Test func unsendRemovesTheTextForBothPeople() async throws {
        let (state, demo, match) = try await AppState.matchedWithMina()
        await state.openThread(match)
        let oops = try await send("wrong chat", state, match)
        let reply = try await send("ignore that", state, match, replyingTo: oops)
        await state.toggleReaction("👍", on: oops.id, in: match)

        await state.unsend(oops.id, in: match)
        let local = state.thread(match).messages
        #expect(local.first { $0.id == oops.id }?.isDeleted == true)
        #expect(local.first { $0.id == oops.id }?.body == "")
        #expect(local.first { $0.id == reply.id }?.replyTo?.isDeleted == true, "quotes of it lose their text too")

        let server = try await demo.fetchMessages(matchID: match, before: nil, limit: 50).first { $0.id == oops.id }
        #expect(server?.isDeleted == true && server?.body == "" && server?.reactions.isEmpty == true)
        #expect(state.conversation(with: match)?.lastMessagePreview != "wrong chat")

        // Only my own text messages can be unsent; a reaction can't land on an unsent message.
        await #expect(throws: CrushlyError.self) { try await demo.react(messageID: oops.id, emoji: "❤️") }
    }

    @Test func screenshotLeavesANoticeAndBurstsCollapse() async throws {
        let (state, demo, match) = try await AppState.matchedWithMina()
        await state.openThread(match)
        await state.recordScreenshot(in: match)
        await state.recordScreenshot(in: match)
        let notices = try await demo.fetchMessages(matchID: match, before: nil, limit: 50).filter { $0.kind == .screenshot }
        #expect(notices.count == 1)
        #expect(state.thread(match).messages.last?.kind == .screenshot)
        await state.refreshConversations()
        #expect(state.conversation(with: match)?.previewLine == "You took a screenshot")
        // A notice is not evidence and can't be unsent or reacted to.
        await #expect(throws: CrushlyError.self) { try await demo.unsendMessage(messageID: notices[0].id) }
    }

    @Test func oldCachesStillDecode() throws {
        let legacy = #"{"messages":[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","senderIsMe":true,"body":"hi","createdAt":0}],"pending":[]}"#
        let thread = try JSONDecoder().decode(CachedThread.self, from: Data(legacy.utf8))
        #expect(thread.messages.first?.kind == .text)
        #expect(thread.messages.first?.reactions.isEmpty == true)
        #expect(thread.messages.first?.replyTo == nil)
    }

    @Test func rowsGroupBubblesAndInsertTimeSeparators() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func m(_ seconds: TimeInterval, me: Bool, kind: ChatMessage.Kind = .text) -> ChatMessage {
            ChatMessage(id: UUID(), senderIsMe: me, body: kind == .text ? "x" : "", createdAt: start.addingTimeInterval(seconds), kind: kind)
        }
        let messages = [m(0, me: false), m(10, me: false), m(20, me: true), m(25, me: true, kind: .screenshot),
                        m(30, me: true), m(3600, me: true)]
        let rows = ChatRows.build(messages: messages, pending: [])
        let groups: [ChatRows.Group?] = rows.map { if case .message(_, let g) = $0.kind { g } else { nil } }
        let times = rows.filter { if case .time = $0.kind { true } else { false } }.count
        #expect(times == 2, "one at the start and one after an hour of silence")
        #expect(groups.compactMap { $0 }.map { [$0.first, $0.last] } == [
            [true, false], [false, true],   // two from Mina stack; the second gets the tail
            [true, true],                   // the screenshot notice breaks my run
            [true, true],
            [true, true],                   // new run after the time separator
        ])
        #expect(groups.compactMap { $0 }.last?.delivered == true, "Delivered sits under my newest message")
    }
}
