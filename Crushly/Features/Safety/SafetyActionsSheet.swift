import SwiftUI

/// Block / report from a profile or a conversation. Both act on the server immediately.
/// From a conversation, the reporter can choose specific messages as evidence before the conversation is deleted.
struct SafetyActionsSheet: View {
    let person: PublicProfile
    var matchID: UUID?
    var onDone: () -> Void

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var category: ReportCategory?
    @State private var details = ""
    @State private var evidence: Set<UUID> = []
    @State private var confirmBlock = false

    /// Only live text can be evidence: unsent messages and screenshot notices carry nothing.
    private var messages: [ChatMessage] { matchID.map { state.thread($0).messages.filter(\.isLiveText) } ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button(role: .destructive) { confirmBlock = true } label: {
                        Label("Block \(person.firstName)", systemImage: "hand.raised.fill")
                    }
                    .accessibilityIdentifier("safety.block")
                } footer: {
                    Text("Any match and conversation with \(person.firstName) ends for both of you. You won't see each other or be able to match or message again. They aren't notified.")
                }

                Section("Report") {
                    Picker("Reason", selection: $category) {
                        Text("Choose a reason").tag(ReportCategory?.none)
                        ForEach(ReportCategory.allCases) { Text($0.title).tag(Optional($0)) }
                    }
                    .accessibilityIdentifier("safety.reason")
                    TextField("What happened? (optional)", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                }

                if matchID != nil {
                    Section {
                        if messages.isEmpty {
                            Text("No messages in this conversation.").foregroundStyle(Theme.Palette.inkSoft)
                        }
                        ForEach(messages) { message in
                            Button { toggle(message.id) } label: {
                                HStack(alignment: .top, spacing: Theme.Space.m) {
                                    Image(systemName: evidence.contains(message.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(evidence.contains(message.id) ? Theme.Palette.crush : Theme.Palette.inkFaint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(message.senderIsMe ? "You" : person.firstName)
                                            .font(Theme.Typeface.caption.weight(.bold))
                                            .foregroundStyle(Theme.Palette.inkSoft)
                                        Text(message.body).font(Theme.Typeface.subheadline).foregroundStyle(Theme.Palette.ink)
                                    }
                                }
                            }
                            .accessibilityAddTraits(evidence.contains(message.id) ? .isSelected : [])
                            .disabled(!evidence.contains(message.id) && evidence.count >= 50)
                        }
                    } header: {
                        Text("Include messages (optional)")
                    } footer: {
                        Text("Only the messages you select are sent to Crushly's safety team, kept for up to 90 days, then deleted. Reporting deletes the conversation, so choose now.")
                    }
                }

                Section {
                    AsyncButton {
                        guard let category else { return }
                        if await state.perform({
                            try await state.report(person.id, category: category, details: details,
                                                   evidenceMessageIDs: messages.map(\.id).filter(evidence.contains))
                        }) {
                            state.feedback.play(.success)
                            dismiss()
                            onDone()
                        }
                    } label: { Text("Submit report") }
                        .disabled(category == nil)
                        .accessibilityIdentifier("safety.submitReport")
                } footer: {
                    Text("Reports are private: \(person.firstName) won't see who reported them. Reporting also blocks them and ends any conversation for both of you. Deleting a conversation can't remove screenshots or copies on a device that's offline.")
                }

                Section {
                    Label("If you meet, choose a public place and tell a friend where you're going.", systemImage: "person.2.fill")
                        .font(Theme.Typeface.footnote)
                }
            }
            .foregroundStyle(Theme.Palette.ink, Theme.Palette.inkSoft)   // section headers/footers readable on paper
            .navigationTitle("Safety")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .confirmationDialog("Block \(person.firstName)?", isPresented: $confirmBlock, titleVisibility: .visible) {
                Button("Block", role: .destructive) {
                    Task {
                        if await state.perform({ try await state.block(person.id) }) {
                            dismiss()
                            onDone()
                        }
                    }
                }
            } message: {
                Text("This ends any conversation with \(person.firstName) for both of you.")
            }
        }
        .closesForReveal()
    }

    private func toggle(_ id: UUID) {
        if evidence.contains(id) { evidence.remove(id) } else if evidence.count < 50 { evidence.insert(id) }
    }
}
