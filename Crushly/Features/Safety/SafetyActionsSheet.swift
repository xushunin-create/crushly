import SwiftUI

/// Block / report from a profile or connection. Both act on the server immediately.
struct SafetyActionsSheet: View {
    let person: PublicProfile
    var onDone: () -> Void

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var category: ReportCategory?
    @State private var details = ""
    @State private var confirmBlock = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button(role: .destructive) { confirmBlock = true } label: {
                        Label("Block \(person.firstName)", systemImage: "hand.raised.fill")
                    }
                } footer: {
                    Text("They won't see you, signal you, or interact with you, and you won't see them. They aren't notified.")
                }

                Section("Report") {
                    Picker("Reason", selection: $category) {
                        Text("Choose a reason").tag(ReportCategory?.none)
                        ForEach(ReportCategory.allCases) { Text($0.title).tag(Optional($0)) }
                    }
                    TextField("What happened? (optional)", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                    AsyncButton {
                        guard let category else { return }
                        if await state.perform({ try await state.report(person.id, category: category, details: details) }) {
                            state.feedback.play(.success)
                            dismiss()
                            onDone()
                        }
                    } label: { Text("Submit report") }
                        .disabled(category == nil)
                }

                Section {
                    Label("Meet in public places and tell a friend where you're going.", systemImage: "person.2.fill")
                        .font(Theme.Typeface.footnote)
                } footer: {
                    Text("Reports are private. \(person.firstName) won't see who reported them. Reporting also blocks them.")
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
            }
        }
        .closesForReveal()
    }
}
