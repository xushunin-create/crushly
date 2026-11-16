import SwiftUI

/// Full-screen mutual match reveal. Covers the tab bar so the moment has focus.
struct HeartSyncRevealView: View {
    let match: Conversation

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var together = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            RetroBackground()

            ScrollView {
            VStack(spacing: Theme.Space.xl) {
                Spacer(minLength: Theme.Space.l)
                Text("Heart Sync")
                    .font(Theme.Typeface.title)
                    .foregroundStyle(Theme.Palette.oxblood)

                portraits

                VStack(spacing: Theme.Space.s) {
                    Text("You noticed\neach other").font(Theme.Typeface.display)
                    Text("The feeling is mutual.").font(Theme.Typeface.title2).foregroundStyle(Theme.Palette.crushText)
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.Palette.oxblood)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("reveal.headline")

                Spacer(minLength: Theme.Space.l)

                VStack(spacing: Theme.Space.m) {
                    Button { state.openConversation(match.id) } label: {
                        Label("Send a message", systemImage: "bubble.left.and.bubble.right.fill")
                    }
                    .buttonStyle(.crush)
                    .accessibilityIdentifier("reveal.message")
                    Button("Keep exploring") { dismiss() }
                        .accessibilityIdentifier("reveal.keepExploring")
                        .font(Theme.Typeface.button)
                        .foregroundStyle(Theme.Palette.inkSoft)
                        .frame(minHeight: Theme.minTap)
                }
            }
            .padding(Theme.Space.gutter)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onAppear {
            withAnimation(reduceMotion ? .none : .spring(response: 0.8, dampingFraction: 0.65).delay(0.15)) { together = true }
            if !reduceMotion { pulse = true }
            UIAccessibility.post(notification: .announcement, argument: "Heart Sync. You matched with \(match.other.firstName).")
        }
    }

    private var portraits: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Theme.Palette.blush.opacity(0.20 - Double(index) * 0.045))
                    .overlay {
                        Circle().stroke(Theme.Palette.crush.opacity(0.30 - Double(index) * 0.07), lineWidth: 2)
                    }
                    .frame(width: CGFloat(220 + index * 50))
                    .scaleEffect(pulse ? 1.15 : 0.85)
                    .opacity(pulse ? 0.2 : 0.8)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true).delay(Double(index) * 0.15), value: pulse)
            }
            HStack(spacing: together ? -26 : 60) {
                Avatar(path: state.profile?.photoPaths.first, name: state.profile?.firstName ?? "", size: 128)
                    .overlay(Circle().stroke(.white, lineWidth: 4))
                Avatar(path: match.other.photoPaths.first, name: match.other.firstName, size: 128)
                    .overlay(Circle().stroke(.white, lineWidth: 4))
            }
            Image(systemName: "heart.fill")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(Theme.Palette.crush)
                .padding(14)
                .background(.white, in: Circle())
                .overlay(SparkRays().offset(y: -48))
                .offset(y: 70)
                .scaleEffect(together ? 1 : 0.2)
                .opacity(together ? 1 : 0)
        }
        .frame(height: 260)
        .accessibilityElement()
        .accessibilityLabel("You and \(match.other.firstName)")
    }
}
