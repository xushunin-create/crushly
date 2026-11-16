import SwiftUI

/// "Open to matching here?" — asked once per visit. Dismissing or ignoring it means invisible.
struct ConsentSheet: View {
    let prompt: AppState.ConsentPrompt

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var chose = false

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Image(systemName: "heart.circle.fill")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(Theme.Palette.crush)
                .accessibilityHidden(true)
            Text("Open to matching here?")
                .font(Theme.Typeface.title)
                .foregroundStyle(Theme.Palette.oxblood)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("consent.title")
            Text("You're at \(prompt.spaceName). Choose whether you'd like to discover mutual connections during this visit. Your precise location is never shown.")
                .font(Theme.Typeface.body)
                .foregroundStyle(Theme.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Label("People matching here may infer you're in the same campus space.", systemImage: "info.circle")
                .font(Theme.Typeface.footnote)
                .foregroundStyle(Theme.Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Theme.Space.l)

            VStack(spacing: Theme.Space.m) {
                AsyncButton {
                    chose = true
                    dismiss()
                    await state.openToMatching()
                } label: { Text("Open to matching") }
                    .buttonStyle(.crush)
                    .accessibilityIdentifier("consent.open")
                Button("Stay invisible") {
                    chose = true
                    state.stayInvisible(visit: prompt.visit)
                    dismiss()
                }
                .buttonStyle(.crush(.secondary))
                .accessibilityIdentifier("consent.invisible")
            }
        }
        .padding(Theme.Space.gutter)
        }
        .background(Theme.Palette.paper)
        .presentationDetents([.large])
        .onDisappear {
            // Swiping the sheet away is a choice to stay invisible for this visit.
            if !chose { state.stayInvisible(visit: prompt.visit) }
        }
        .closesForReveal()
    }
}
