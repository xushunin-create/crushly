import SwiftUI

/// One-to-one chat. Messages are protected in transit and at rest but are NOT end-to-end encrypted (the privacy
/// screen says so). Shows sending / sent / failed states; retry reuses the same client message id.
struct ChatThreadView: View {
    let matchID: UUID

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
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
        .onDisappear { state.closeThread(matchID) }
    }

    private func content(_ conversation: Conversation) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Theme.Space.s) {
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
                        ForEach(thread.messages) { message in
                            Bubble(text: message.body, fromMe: message.senderIsMe, status: nil)
                                .id(message.id)
                        }
                        ForEach(thread.pending) { pending in
                            Bubble(text: pending.body, fromMe: true, status: pending.state)
                                .id(pending.id)
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
                        if let error = thread.error {
                            Label(error, systemImage: "wifi.exclamationmark")
                                .font(Theme.Typeface.footnote)
                                .foregroundStyle(Theme.Palette.inkSoft)
                                .padding(.top, Theme.Space.s)
                        }
                    }
                    .padding(.horizontal, Theme.Space.gutter)
                    .padding(.vertical, Theme.Space.m)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: thread.messages.count + thread.pending.count) { _, _ in
                    if let last = thread.pending.last?.id ?? thread.messages.last?.id {
                        withAnimation(Theme.Motion.soft) { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            composer
        }
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

    private func starter(_ conversation: Conversation) -> some View {
        VStack(spacing: Theme.Space.m) {
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

    private var composer: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.s) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($composerFocused)
                .font(Theme.Typeface.body)
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, 12)
                .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.Palette.hairline))
                .accessibilityIdentifier("chat.composer")
            Button {
                let text = draft
                draft = ""
                Task { await state.sendMessage(text, in: matchID) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(canSend ? Theme.Palette.crush : Theme.Palette.inkFaint)
                    .frame(width: Theme.minTap, height: Theme.minTap)
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("chat.send")
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.Palette.paper.opacity(0.97))
    }

    private var canSend: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= state.rules.messageMaxChars
    }
}

private struct Bubble: View {
    let text: String
    let fromMe: Bool
    /// nil = confirmed by the server ("sent").
    let status: PendingMessage.State?

    var body: some View {
        VStack(alignment: fromMe ? .trailing : .leading, spacing: 3) {
            Text(text)
                .font(Theme.Typeface.body)
                .foregroundStyle(fromMe ? .white : Theme.Palette.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(fromMe ? Theme.Palette.oxblood : Theme.Palette.surface,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(fromMe ? .clear : Theme.Palette.hairline))
                .opacity(status == .sending ? 0.7 : 1)
            if fromMe, let status {
                Label(status == .sending ? "Sending…" : "Not sent. Tap to retry", systemImage: status == .sending ? "clock" : "exclamationmark.circle.fill")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(status == .failed ? Theme.Palette.danger : Theme.Palette.inkSoft)
            }
        }
        .frame(maxWidth: .infinity, alignment: fromMe ? .trailing : .leading)
        .padding(fromMe ? .leading : .trailing, 48)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(fromMe ? "You" : "Them"): \(text)\(status == .sending ? ", sending" : status == .failed ? ", not sent, double tap to retry" : "")")
    }
}
