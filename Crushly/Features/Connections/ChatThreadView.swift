import SwiftUI
import UIKit

/// One-to-one chat, modelled on Messages: grouped bubbles with tails, time separators, tapback-style reactions,
/// swipe (or long-press) to reply, unsend, and a notice when someone screenshots the conversation.
///
/// Text only: there is deliberately no way to send photos or attachments. Messages are protected in transit and at
/// rest but are NOT end-to-end encrypted (the privacy screen says so). Retry reuses the same client message id.
struct ChatThreadView: View {
    let matchID: UUID

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var replyingTo: ChatMessage?
    @State private var focused: ChatMessage?
    @State private var emojiPickerFor: ChatMessage?
    @State private var unsendCandidate: ChatMessage?
    @State private var highlighted: UUID?
    @State private var showProfile = false
    @State private var showSafety = false
    @State private var confirmLeave = false
    @FocusState private var composerFocused: Bool

    private var conversation: Conversation? { state.conversation(with: matchID) }
    private var thread: AppState.ThreadState { state.thread(matchID) }

    var body: some View {
        Group {
            if let conversation {
                content(conversation)
            } else if state.conversationsLoaded {
                EmptyStateView(symbol: "heart.slash", title: "Conversation unavailable",
                               message: "This match has ended.")
            } else {
                ProgressView()
            }
        }
        .background(Theme.Palette.paper)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: matchID) {
            await state.openThread(matchID)
            // Demo fixture only: let scripted replies arrive while the thread is open (live mode gets realtime pokes).
            while state.demo != nil, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                state.demo?.runScriptsNow()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            // Only when this conversation is what's on screen.
            guard !showProfile, !showSafety, emojiPickerFor == nil else { return }
            Task { await state.recordScreenshot(in: matchID) }
        }
        .onDisappear { state.closeThread(matchID) }
    }

    // MARK: Layout

    private func content(_ conversation: Conversation) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if thread.hasMore, !thread.messages.isEmpty {
                            Button { Task { await state.loadOlder(matchID) } } label: {
                                if thread.loading { ProgressView() } else { Text("Load earlier messages") }
                            }
                            .font(Theme.Typeface.subheadline.weight(.semibold))
                            .frame(minHeight: Theme.minTap)
                            .accessibilityIdentifier("chat.loadEarlier")
                        }
                        if thread.messages.isEmpty, thread.pending.isEmpty, !thread.loading {
                            starter(conversation)
                        }
                        ForEach(ChatRows.build(messages: thread.messages, pending: thread.pending)) { row in
                            rowView(row, conversation: conversation, proxy: proxy)
                                .id(row.id)
                        }
                        if let error = thread.error {
                            Label(error, systemImage: "wifi.exclamationmark")
                                .font(Theme.Typeface.footnote)
                                .foregroundStyle(Theme.Palette.inkSoft)
                                .padding(.top, Theme.Space.s)
                        }
                    }
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.m)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: thread.messages.count + thread.pending.count) { _, _ in scrollToBottom(proxy) }
                .onChange(of: composerFocused) { _, focusedNow in if focusedNow { scrollToBottom(proxy) } }
            }
            composer(conversation)
        }
        .overlay {
            if let focused {
                MessageFocusOverlay(
                    message: focused, otherName: conversation.other.firstName,
                    onReact: { emoji in react(emoji, to: focused) },
                    onMoreReactions: { withAnimation(Theme.Motion.snappy) { self.focused = nil }; emojiPickerFor = focused },
                    onReply: { startReply(to: focused) },
                    onCopy: { UIPasteboard.general.string = focused.body; dismissFocus() },
                    onUnsend: { dismissFocus(); unsendCandidate = focused },
                    onDismiss: dismissFocus)
                .transition(.opacity)
            }
        }
        .animation(Theme.Motion.snappy, value: focused)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { showProfile = true } label: {
                    HStack(spacing: Theme.Space.s) {
                        Avatar(path: conversation.other.photoPaths.first, name: conversation.other.firstName, size: 30)
                        Text(conversation.other.firstName).font(Theme.Typeface.headline).foregroundStyle(Theme.Palette.ink)
                    }
                }
                .accessibilityLabel("View \(conversation.other.firstName)'s profile")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showProfile = true } label: { Label("View profile", systemImage: "person.crop.circle") }
                    Button { showSafety = true } label: { Label("Report or block", systemImage: "exclamationmark.shield") }
                    Button(role: .destructive) { confirmLeave = true } label: {
                        Label("Leave & delete conversation", systemImage: "trash")
                    }
                } label: { Image(systemName: "ellipsis.circle").frame(minWidth: Theme.minTap, minHeight: Theme.minTap) }
                .accessibilityLabel("Conversation options")
                .accessibilityIdentifier("chat.options")
            }
        }
        .sheet(isPresented: $showProfile) { PersonProfileView(person: conversation.other, showsInterest: false) }
        .sheet(isPresented: $showSafety) {
            SafetyActionsSheet(person: conversation.other, matchID: matchID) { dismiss() }
                .presentationDetents([.large])
        }
        .sheet(item: $emojiPickerFor) { message in
            EmojiPickerSheet(current: message.myReaction) { emoji in
                emojiPickerFor = nil
                react(emoji, to: message)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog("Unsend this message?", isPresented: Binding(
            get: { unsendCandidate != nil }, set: { if !$0 { unsendCandidate = nil } }), titleVisibility: .visible,
            presenting: unsendCandidate) { message in
            Button("Unsend", role: .destructive) {
                state.feedback.play(.tap)
                Task { await state.unsend(message.id, in: matchID) }
            }
            .accessibilityIdentifier("chat.confirmUnsend")
        } message: { _ in
            Text("It's removed for you and \(conversation.other.firstName). They may already have seen it.")
        }
        .confirmationDialog("Leave & delete this conversation?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave & delete", role: .destructive) {
                Task {
                    if await state.perform({ try await state.leaveConversation(matchID) }) { dismiss() }
                }
            }
            .accessibilityIdentifier("chat.confirmLeave")
        } message: {
            Text("Your match with \(conversation.other.firstName) ends and the conversation history is deleted for both of you. This can't remove screenshots, or copies on a device that's offline.")
        }
    }

    @ViewBuilder
    private func rowView(_ row: ChatRows.Row, conversation: Conversation, proxy: ScrollViewProxy) -> some View {
        let name = conversation.other.firstName
        switch row.kind {
        case .time(let date):
            Text(ChatRows.timestamp(date))
                .font(Theme.Typeface.caption)
                .foregroundStyle(Theme.Palette.inkFaint)
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Space.m)
                .padding(.bottom, Theme.Space.xs)
        case .notice(let message):
            NoticeRow(message: message, otherName: name)
        case .message(let message, let group):
            SwipeToReply(enabled: message.isLiveText) { startReply(to: message) } content: {
                MessageBubble(
                    text: message.body, fromMe: message.senderIsMe, group: group, replyTo: message.replyTo,
                    otherName: name, reactions: message.reactions, status: nil, highlighted: highlighted == message.id,
                    onTapQuote: { message.replyTo.map { jump(to: $0.id, proxy: proxy) } })
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { react("❤️", to: message) }
                .onLongPressGesture(minimumDuration: 0.3) { focus(message) }
                .accessibilityAction(named: "Reply") { startReply(to: message) }
                .accessibilityAction(named: message.myReaction == "❤️" ? "Remove heart" : "Heart") { react("❤️", to: message) }
                .accessibilityAction(named: "More reactions") { emojiPickerFor = message }
                .accessibilityAction(named: "Copy") { UIPasteboard.general.string = message.body }
                .modifier(UnsendAction(enabled: message.senderIsMe) { unsendCandidate = message })
            }
        case .pending(let pending, let group):
            MessageBubble(
                text: pending.body, fromMe: true, group: group, replyTo: pending.replyTo, otherName: name,
                reactions: [], status: pending.state, highlighted: false,
                onTapQuote: { pending.replyTo.map { jump(to: $0.id, proxy: proxy) } })
                .contextMenu {
                    if pending.state == .failed {
                        Button("Retry") { Task { await state.retry(pending.id, in: matchID) } }
                        Button("Delete", role: .destructive) { state.discardPending(pending.id, in: matchID) }
                    }
                }
                .onTapGesture {
                    if pending.state == .failed { Task { await state.retry(pending.id, in: matchID) } }
                }
        }
    }

    private func starter(_ conversation: Conversation) -> some View {
        VStack(spacing: Theme.Space.m) {
            Avatar(path: conversation.other.photoPaths.first, name: conversation.other.firstName, size: 72)
            Text("You and \(conversation.other.firstName) matched. Say hi!")
                .font(Theme.Typeface.headline)
                .multilineTextAlignment(.center)
            FlowLayout(spacing: 8) {
                ForEach(ConversationStarters.all, id: \.self) { line in
                    Button { draft = line; composerFocused = true } label: { Tag(text: line) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, Theme.Space.xl)
    }

    // MARK: Composer

    private func composer(_ conversation: Conversation) -> some View {
        VStack(spacing: 0) {
            if let replyingTo {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Capsule().fill(Theme.Palette.crush).frame(width: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(replyingTo.senderIsMe ? "Replying to yourself" : "Replying to \(conversation.other.firstName)")
                            .font(Theme.Typeface.caption.weight(.bold))
                            .foregroundStyle(Theme.Palette.crushText)
                        Text(replyingTo.body)
                            .font(Theme.Typeface.footnote)
                            .foregroundStyle(Theme.Palette.inkSoft)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { withAnimation(Theme.Motion.snappy) { self.replyingTo = nil } } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Theme.Palette.inkSoft)
                            .frame(width: Theme.minTap, height: Theme.minTap)
                    }
                    .accessibilityLabel("Cancel reply")
                    .accessibilityIdentifier("chat.cancelReply")
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Theme.Space.l)
                .padding(.top, Theme.Space.s)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .contain)
            }
            HStack(alignment: .bottom, spacing: Theme.Space.s) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .font(Theme.Typeface.body)
                    .padding(.leading, 14)
                    .padding(.trailing, 4)
                    .padding(.vertical, 9)
                    .accessibilityIdentifier("chat.composer")
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(canSend ? Theme.Palette.crush : Theme.Palette.inkFaint.opacity(0.45), in: Circle())
                        .frame(width: Theme.minTap, height: 38)
                        .contentShape(Rectangle())
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("chat.send")
            }
            .padding(.leading, 2)
            .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.Palette.hairline))
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            if overLimitWarning {
                Text("\(trimmedDraft.count)/\(state.rules.messageMaxChars)")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(trimmedDraft.count > state.rules.messageMaxChars ? Theme.Palette.danger : Theme.Palette.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.bottom, Theme.Space.xs)
            }
        }
        .background(Theme.Palette.paper.opacity(0.97))
        .animation(Theme.Motion.snappy, value: replyingTo)
    }

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !trimmedDraft.isEmpty && trimmedDraft.count <= state.rules.messageMaxChars }
    private var overLimitWarning: Bool { trimmedDraft.count > state.rules.messageMaxChars - 100 }

    // MARK: Actions

    private func send() {
        let text = draft
        let quote = replyingTo
        draft = ""
        replyingTo = nil
        Task { await state.sendMessage(text, in: matchID, replyingTo: quote) }
    }

    private func focus(_ message: ChatMessage) {
        guard message.isLiveText else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        composerFocused = false
        focused = message
    }

    private func dismissFocus() { focused = nil }

    private func startReply(to message: ChatMessage) {
        guard message.isLiveText else { return }
        focused = nil
        withAnimation(Theme.Motion.snappy) { replyingTo = message }
        composerFocused = true
    }

    private func react(_ emoji: String, to message: ChatMessage) {
        guard message.isLiveText else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        focused = nil
        Task { await state.toggleReaction(emoji, on: message.id, in: matchID) }
    }

    private func jump(to id: UUID, proxy: ScrollViewProxy) {
        guard thread.messages.contains(where: { $0.id == id }) else { return }
        withAnimation(Theme.Motion.soft) { proxy.scrollTo("m-\(id.uuidString)", anchor: .center) }
        highlighted = id
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if highlighted == id { withAnimation(Theme.Motion.soft) { highlighted = nil } }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = ChatRows.build(messages: thread.messages, pending: thread.pending).last?.id else { return }
        withAnimation(Theme.Motion.soft) { proxy.scrollTo(last, anchor: .bottom) }
    }
}

// MARK: - Row model

/// Turns messages + pending sends into display rows: time separators, grouped bubbles and notices.
enum ChatRows {
    struct Group: Equatable {
        /// First / last bubble of a run from the same sender; the last one gets the tail.
        var first: Bool
        var last: Bool
        /// "Delivered" under my newest confirmed message when it's the end of the conversation.
        var delivered: Bool = false
    }

    enum Kind {
        case time(Date)
        case message(ChatMessage, Group)
        case pending(PendingMessage, Group)
        case notice(ChatMessage)
    }

    struct Row: Identifiable {
        let id: String
        let kind: Kind
    }

    /// A new time separator after this much silence (Messages uses about 15 minutes).
    static let separatorGap: TimeInterval = 15 * 60
    /// Bubbles from the same sender closer than this stack together.
    static let groupGap: TimeInterval = 3 * 60

    private enum Item {
        case sent(ChatMessage)
        case pending(PendingMessage)

        var createdAt: Date {
            switch self { case .sent(let m): m.createdAt; case .pending(let p): p.createdAt }
        }
        var fromMe: Bool {
            switch self { case .sent(let m): m.senderIsMe; case .pending: true }
        }
        /// Unsent placeholders and screenshot notices are not bubbles and break a run.
        var isBubble: Bool {
            switch self { case .sent(let m): m.isLiveText; case .pending: true }
        }
    }

    static func build(messages: [ChatMessage], pending: [PendingMessage]) -> [Row] {
        let items: [Item] = messages.map(Item.sent) + pending.map(Item.pending)
        var rows: [Row] = []
        var separatorBefore = [Bool](repeating: false, count: items.count)
        for i in items.indices {
            separatorBefore[i] = i == 0 || items[i].createdAt.timeIntervalSince(items[i - 1].createdAt) > separatorGap
        }
        func joins(_ a: Int, _ b: Int) -> Bool {
            guard items.indices.contains(a), items.indices.contains(b) else { return false }
            return items[a].isBubble && items[b].isBubble && items[a].fromMe == items[b].fromMe && !separatorBefore[b]
                && items[b].createdAt.timeIntervalSince(items[a].createdAt) <= groupGap
        }
        let lastConfirmedMine = messages.indices.last.flatMap { i in
            messages[i].senderIsMe && messages[i].isLiveText && pending.isEmpty ? i : nil
        }
        for (i, item) in items.enumerated() {
            if separatorBefore[i] {
                rows.append(Row(id: "t-\(item.createdAt.timeIntervalSince1970)", kind: .time(item.createdAt)))
            }
            let group = Group(first: !joins(i - 1, i), last: !joins(i, i + 1))
            switch item {
            case .sent(let message):
                if message.isLiveText {
                    var g = group
                    g.delivered = i == lastConfirmedMine
                    rows.append(Row(id: "m-\(message.id.uuidString)", kind: .message(message, g)))
                } else {
                    rows.append(Row(id: "m-\(message.id.uuidString)", kind: .notice(message)))
                }
            case .pending(let p):
                rows.append(Row(id: "m-\(p.id.uuidString)", kind: .pending(p, group)))
            }
        }
        return rows
    }

    /// "Today 3:41 PM", "Yesterday 9:02 AM", "Tuesday 6:15 PM", "Nov 3 at 6:15 PM".
    static func timestamp(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> AttributedString {
        let time = date.formatted(date: .omitted, time: .shortened)
        let day: String
        if calendar.isDateInToday(date) {
            day = "Today"
        } else if calendar.isDateInYesterday(date) {
            day = "Yesterday"
        } else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day,
                  days < 7 {
            day = date.formatted(.dateTime.weekday(.wide))
        } else {
            day = date.formatted(.dateTime.month(.abbreviated).day())
        }
        var bold = AttributedString(day)
        bold.font = Theme.Typeface.caption.weight(.bold)
        return bold + AttributedString(" \(time)")
    }
}

// MARK: - Bubbles

private struct MessageBubble: View {
    let text: String
    let fromMe: Bool
    let group: ChatRows.Group
    let replyTo: ReplyPreview?
    let otherName: String
    let reactions: [MessageReaction]
    /// nil = confirmed by the server.
    let status: PendingMessage.State?
    let highlighted: Bool
    var onTapQuote: () -> Void = {}

    private var bigEmoji: Bool { text.count <= 3 && text.allSatisfy(\.isEmojiGlyph) }

    var body: some View {
        VStack(alignment: fromMe ? .trailing : .leading, spacing: 3) {
            if let replyTo {
                ReplyQuote(reply: replyTo, fromMe: fromMe, otherName: otherName)
                    .onTapGesture(perform: onTapQuote)
                    .padding(.top, group.first ? Theme.Space.s : 2)
            }
            bubble
                .overlay(alignment: fromMe ? .topLeading : .topTrailing) {
                    if !reactions.isEmpty {
                        ReactionBadge(reactions: reactions)
                            .offset(x: fromMe ? -14 : 14, y: -16)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .animation(Theme.Motion.snappy, value: reactions)
            if let status {
                Label(status == .sending ? "Sending…" : "Not delivered. Tap to retry",
                      systemImage: status == .sending ? "clock" : "exclamationmark.circle.fill")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(status == .failed ? Theme.Palette.danger : Theme.Palette.inkSoft)
                    .padding(.trailing, 4)
            } else if group.delivered {
                Text("Delivered")
                    .font(Theme.Typeface.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.inkFaint)
                    .padding(.trailing, 4)
            }
        }
        .padding(.top, (reactions.isEmpty ? 0 : 14) + (group.first && replyTo == nil ? 6 : 0))
        .padding(.bottom, group.last ? 4 : 0)
        .frame(maxWidth: .infinity, alignment: fromMe ? .trailing : .leading)
        .padding(fromMe ? .leading : .trailing, 52)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var bubble: some View {
        if bigEmoji {
            Text(text)
                .font(.system(size: 46))
                .padding(.horizontal, 2)
                .scaleEffect(highlighted ? 1.08 : 1)
        } else {
            Text(text)
                .font(Theme.Typeface.body)
                .foregroundStyle(fromMe ? .white : Theme.Palette.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background {
                    BubbleShape(fromMe: fromMe, tail: group.last, joinTop: !group.first, joinBottom: !group.last)
                        .fill(fromMe ? Theme.Palette.oxblood : Color.white)
                        .shadow(color: Theme.Palette.oxblood.opacity(fromMe ? 0 : 0.06), radius: 1, y: 1)
                }
                .opacity(status == .sending ? 0.7 : 1)
                .scaleEffect(highlighted ? 1.04 : 1)
                .textSelection(.disabled)
        }
    }

    private var accessibilityText: String {
        var parts = ["\(fromMe ? "You" : otherName): \(text)"]
        if let replyTo { parts.insert("Reply to \(replyTo.senderIsMe ? "you" : otherName)", at: 0) }
        if !reactions.isEmpty {
            parts.append(reactions.map { "\($0.fromMe ? "You" : otherName) reacted \($0.emoji)" }.joined(separator: ", "))
        }
        if status == .sending { parts.append("sending") }
        if status == .failed { parts.append("not delivered, double tap to retry") }
        if group.delivered { parts.append("delivered") }
        return parts.joined(separator: ". ")
    }
}

/// A Messages-style bubble: rounded, with a curled tail on the last bubble of a run and tighter corners where
/// bubbles from the same sender stack.
struct BubbleShape: Shape {
    var fromMe: Bool
    var tail: Bool
    var joinTop: Bool
    var joinBottom: Bool

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let big = min(18, h / 2)
        let small = min(6, big)
        let tr = joinTop ? small : big
        let br = joinBottom ? small : big
        var p = Path()
        p.move(to: CGPoint(x: big, y: 0))
        p.addLine(to: CGPoint(x: w - tr, y: 0))
        p.addArc(tangent1End: CGPoint(x: w, y: 0), tangent2End: CGPoint(x: w, y: tr), radius: tr)
        if tail {
            p.addLine(to: CGPoint(x: w, y: max(tr, h - 12)))
            p.addQuadCurve(to: CGPoint(x: w + 6, y: h), control: CGPoint(x: w, y: h - 1))
            p.addQuadCurve(to: CGPoint(x: w - 12, y: h - 3), control: CGPoint(x: w - 3, y: h + 0.5))
            p.addQuadCurve(to: CGPoint(x: max(big, w - 22), y: h), control: CGPoint(x: w - 16, y: h))
        } else {
            p.addLine(to: CGPoint(x: w, y: h - br))
            p.addArc(tangent1End: CGPoint(x: w, y: h), tangent2End: CGPoint(x: w - br, y: h), radius: br)
        }
        p.addLine(to: CGPoint(x: big, y: h))
        p.addArc(tangent1End: CGPoint(x: 0, y: h), tangent2End: CGPoint(x: 0, y: h - big), radius: big)
        p.addLine(to: CGPoint(x: 0, y: big))
        p.addArc(tangent1End: .zero, tangent2End: CGPoint(x: big, y: 0), radius: big)
        p.closeSubpath()
        if !fromMe { p = p.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)) }
        return p.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

private struct ReplyQuote: View {
    let reply: ReplyPreview
    let fromMe: Bool
    let otherName: String

    var body: some View {
        VStack(alignment: fromMe ? .trailing : .leading, spacing: 2) {
            Label(caption, systemImage: "arrowshape.turn.up.left.fill")
                .font(Theme.Typeface.caption)
                .foregroundStyle(Theme.Palette.inkFaint)
                .labelStyle(.titleAndIcon)
            Group {
                if reply.isDeleted {
                    Text("Unsent message").italic()
                } else {
                    Text(reply.body)
                }
            }
            .font(Theme.Typeface.footnote)
            .foregroundStyle(Theme.Palette.inkSoft)
            .lineLimit(2)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.Palette.hairline))
        }
        .padding(fromMe ? .trailing : .leading, 8)
    }

    private var caption: String {
        let replier = fromMe ? "You" : otherName
        let target = reply.senderIsMe ? (fromMe ? "yourself" : "you") : (fromMe ? otherName : "themselves")
        return "\(replier) replied to \(target)"
    }
}

private struct ReactionBadge: View {
    let reactions: [MessageReaction]

    var body: some View {
        let mine = reactions.contains(where: \.fromMe)
        let emojis = reactions.map(\.emoji).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        HStack(spacing: 1) {
            ForEach(emojis, id: \.self) { Text($0) }
            if emojis.count == 1, reactions.count > 1 {
                Text("\(reactions.count)").font(Theme.Typeface.caption.weight(.heavy)).foregroundStyle(mine ? .white : Theme.Palette.ink)
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(mine ? Theme.Palette.crush : Color.white, in: Capsule())
        .overlay(Capsule().stroke(Theme.Palette.paper, lineWidth: 2))
        .shadow(color: Theme.Palette.oxblood.opacity(0.15), radius: 3, y: 1)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityHidden(true)
    }
}

private struct NoticeRow: View {
    let message: ChatMessage
    let otherName: String

    var body: some View {
        if message.kind == .screenshot {
            Label(message.senderIsMe ? "You took a screenshot" : "\(otherName) took a screenshot", systemImage: "camera.viewfinder")
                .font(Theme.Typeface.caption.weight(.semibold))
                .foregroundStyle(Theme.Palette.inkSoft)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.s)
                .accessibilityIdentifier("chat.screenshotNotice")
        } else {
            Text(message.senderIsMe ? "You unsent a message" : "\(otherName) unsent a message")
                .font(Theme.Typeface.caption)
                .italic()
                .foregroundStyle(Theme.Palette.inkFaint)
                .frame(maxWidth: .infinity, alignment: message.senderIsMe ? .trailing : .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .accessibilityIdentifier("chat.unsentNotice")
        }
    }
}

// MARK: - Gestures

/// Drag a bubble to the right to reply, like Messages. Vertical scrolling is left alone.
private struct SwipeToReply<Content: View>: View {
    let enabled: Bool
    let onReply: () -> Void
    @ViewBuilder let content: Content
    @State private var offset: CGFloat = 0
    @State private var armed = false

    private let threshold: CGFloat = 56

    init(enabled: Bool, onReply: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.enabled = enabled
        self.onReply = onReply
        self.content = content()
    }

    var body: some View {
        content
            .offset(x: offset)
            .background(alignment: .leading) {
                if offset > 8 {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(armed ? Theme.Palette.crush : Theme.Palette.inkFaint)
                        .frame(width: 32, height: 32)
                        .background(Color.white, in: Circle())
                        .scaleEffect(armed ? 1.1 : min(1, offset / threshold))
                        .opacity(min(1, offset / threshold))
                        .accessibilityHidden(true)
                }
            }
            .simultaneousGesture(drag, including: enabled ? .all : .subviews)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onChanged { value in
                let dx = value.translation.width, dy = value.translation.height
                guard dx > 0, abs(dx) > abs(dy) * 1.6 else {
                    if offset != 0 { withAnimation(Theme.Motion.snappy) { offset = 0; armed = false } }
                    return
                }
                offset = min(dx * 0.7, threshold + 16)
                let nowArmed = offset >= threshold
                if nowArmed != armed {
                    armed = nowArmed
                    if nowArmed { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                }
            }
            .onEnded { _ in
                if armed { onReply() }
                withAnimation(Theme.Motion.snappy) { offset = 0; armed = false }
            }
    }
}

private struct UnsendAction: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityAction(named: "Unsend", action)
        } else {
            content
        }
    }
}

// MARK: - Long-press menu

/// Long-press a message: the rest of the chat blurs, a reaction bar sits above the message and actions below it.
private struct MessageFocusOverlay: View {
    let message: ChatMessage
    let otherName: String
    let onReact: (String) -> Void
    let onMoreReactions: () -> Void
    let onReply: () -> Void
    let onCopy: () -> Void
    let onUnsend: () -> Void
    let onDismiss: () -> Void

    @State private var appeared = false

    static let quickReactions = ["❤️", "👍", "👎", "😂", "‼️", "❓"]

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Theme.Palette.paper.opacity(0.35))
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Close")

            VStack(alignment: message.senderIsMe ? .trailing : .leading, spacing: Theme.Space.m) {
                reactionBar
                MessageBubble(text: message.body, fromMe: message.senderIsMe,
                              group: ChatRows.Group(first: true, last: true), replyTo: nil, otherName: otherName,
                              reactions: [], status: nil, highlighted: false)
                    .padding(message.senderIsMe ? .leading : .trailing, -52)
                    .allowsHitTesting(false)
                actions
            }
            .frame(maxWidth: .infinity, alignment: message.senderIsMe ? .trailing : .leading)
            .padding(.horizontal, Theme.Space.l)
            .scaleEffect(appeared ? 1 : 0.92, anchor: message.senderIsMe ? .trailing : .leading)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear { withAnimation(Theme.Motion.snappy) { appeared = true } }
        .accessibilityAction(.escape, onDismiss)
    }

    private var reactionBar: some View {
        HStack(spacing: 2) {
            ForEach(Self.quickReactions, id: \.self) { emoji in
                let selected = message.myReaction == emoji
                Button { onReact(emoji) } label: {
                    Text(emoji)
                        .font(.system(size: 25))
                        .frame(width: 40, height: 40)
                        .background(selected ? Theme.Palette.crushSoft : .clear, in: Circle())
                        .scaleEffect(appeared ? 1 : 0.3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(selected ? "Remove \(emoji)" : "React \(emoji)")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("chat.react.\(emoji)")
            }
            Button(action: onMoreReactions) {
                Image(systemName: "face.smiling")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.Palette.inkSoft)
                    .frame(width: 38, height: 38)
                    .background(Theme.Palette.ink.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More reactions")
            .accessibilityIdentifier("chat.react.more")
        }
        .padding(5)
        .background(Color.white, in: Capsule())
        .shadow(color: Theme.Palette.oxblood.opacity(0.16), radius: 14, y: 4)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    private var actions: some View {
        VStack(spacing: 0) {
            actionRow("Reply", "arrowshape.turn.up.left", id: "chat.action.reply", action: onReply)
            Divider().overlay(Theme.Palette.hairline)
            actionRow("Copy", "doc.on.doc", id: "chat.action.copy", action: onCopy)
            if message.senderIsMe {
                Divider().overlay(Theme.Palette.hairline)
                actionRow("Unsend", "arrow.uturn.backward", id: "chat.action.unsend", destructive: true, action: onUnsend)
            }
        }
        .frame(width: 230)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Theme.Palette.oxblood.opacity(0.16), radius: 14, y: 4)
    }

    private func actionRow(_ title: String, _ icon: String, id: String, destructive: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: icon)
            }
            .font(Theme.Typeface.body)
            .foregroundStyle(destructive ? Theme.Palette.danger : Theme.Palette.ink)
            .padding(.horizontal, Theme.Space.l)
            .frame(minHeight: Theme.minTap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// The full emoji choice, opened from the reaction bar.
private struct EmojiPickerSheet: View {
    let current: String?
    let onPick: (String) -> Void

    static let emojis: [String] = """
    ❤️ 🧡 💛 💚 💙 💜 🖤 🤍 💕 💖 😍 🥰 😘 😊 🙂 😉 😂 🤣 😭 🥹 😅 😆 😮 😯 😳 🥺 😢 😡 \
    🙄 😴 🤔 🤨 😎 🤩 🥳 😇 🫶 👏 🙌 🙏 👍 👎 👌 ✌️ 🤞 💪 👀 🔥 ✨ 💯 ‼️ ❓ ❗️ 🎉 💀 🫠 \
    ☕️ 🍕 🌮 🍜 🍦 🎶 📚 🏀 ⚽️ 🎮 🌞 🌙
    """.split(separator: " ").map(String.init)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                    ForEach(Self.emojis, id: \.self) { emoji in
                        Button { onPick(emoji) } label: {
                            Text(emoji)
                                .font(.system(size: 30))
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(current == emoji ? Theme.Palette.crushSoft : .clear,
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(emoji)
                    }
                }
                .padding(Theme.Space.l)
            }
            .navigationTitle("React")
            .navigationBarTitleDisplayMode(.inline)
            .background(Theme.Palette.paper)
        }
    }
}

private extension Character {
    /// True for characters drawn as an emoji (not digits or "#", which are technically emoji-capable).
    var isEmojiGlyph: Bool {
        guard let first = unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation || (first.properties.isEmoji && unicodeScalars.count > 1)
    }
}
