import SwiftUI

/// Full-screen mutual match reveal. Covers the tab bar so the moment has focus.
struct HeartSyncRevealView: View {
    let match: Conversation
    var previewMode = false

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var together = false
    @State private var pulse = false
    @State private var showReveal = false

    var body: some View {
        ZStack {
            RetroBackground()
            matchBackdrop

            ScrollView {
            VStack(spacing: Theme.Space.xl) {
                Spacer(minLength: Theme.Space.l)
                Text(showReveal ? "Heart Sync" : "")
                    .font(Theme.Typeface.title)
                    .foregroundStyle(Theme.Palette.oxblood)
                    .frame(height: 30)

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
                .opacity(showReveal ? 1 : 0)
                .offset(y: showReveal ? 0 : 16)

                Spacer(minLength: Theme.Space.l)

                VStack(spacing: Theme.Space.m) {
                    Button {
                        if previewMode { dismiss() }
                        else { state.openConversation(match.id) }
                    } label: {
                        Label(previewMode ? "Close preview" : "Send a message",
                              systemImage: previewMode ? "xmark" : "bubble.left.and.bubble.right.fill")
                    }
                    .buttonStyle(.crush)
                    .accessibilityIdentifier("reveal.message")
                    Button("Keep exploring") { dismiss() }
                        .accessibilityIdentifier("reveal.keepExploring")
                        .font(Theme.Typeface.button)
                        .foregroundStyle(Theme.Palette.inkSoft)
                        .frame(minHeight: Theme.minTap)
                }
                .opacity(showReveal ? 1 : 0)
                .offset(y: showReveal ? 0 : 16)
                .allowsHitTesting(showReveal)
            }
            .padding(Theme.Space.gutter)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onAppear {
            playReveal()
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
                    .scaleEffect(pulse ? 1.15 : 0.72)
                    .opacity(pulse ? 0.18 : 0)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true).delay(Double(index) * 0.15), value: pulse)
            }
            HStack(spacing: together ? -34 : 92) {
                portrait(path: state.profile?.photoPaths.first, name: state.profile?.firstName ?? "You")
                portrait(path: match.other.photoPaths.first, name: match.other.firstName)
            }
            .scaleEffect(together ? 1 : 0.88)
            Image(systemName: "heart.fill")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(Theme.Palette.crush)
                .padding(14)
                .background(.white, in: Circle())
                .overlay { if showReveal { SparkRays().offset(y: -48) } }
                .offset(y: 70)
                .scaleEffect(together ? 1 : 0.2)
                .opacity(together ? 1 : 0)
        }
        .frame(height: 260)
        .accessibilityElement()
        .accessibilityLabel("You and \(match.other.firstName)")
    }

    private func playReveal() {
        guard !reduceMotion else {
            together = true
            pulse = true
            showReveal = true
            UIAccessibility.post(notification: .announcement, argument: "Heart Sync. You matched with \(match.other.firstName).")
            return
        }

        withAnimation(.spring(response: 0.62, dampingFraction: 0.66).delay(0.12)) { together = true }
        Task {
            try? await Task.sleep(for: .milliseconds(560))
            guard !Task.isCancelled else { return }
            pulse = true
            try? await Task.sleep(for: .milliseconds(430))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { showReveal = true }
            UIAccessibility.post(notification: .announcement, argument: "Heart Sync. You matched with \(match.other.firstName).")
        }
    }

    private func portrait(path: String?, name: String) -> some View {
        Avatar(path: path, name: name, size: 128)
            .overlay(Circle().stroke(.white, lineWidth: 5))
            .overlay(Circle().stroke(Theme.Palette.crush.opacity(0.28), lineWidth: 1))
            .shadow(color: Theme.Palette.oxblood.opacity(0.14), radius: 14, y: 7)
    }

    private var matchBackdrop: some View {
        GeometryReader { proxy in
            ZStack {
                Capsule()
                    .fill(Theme.Palette.orange.opacity(0.10))
                    .frame(width: proxy.size.width * 1.25, height: 82)
                    .rotationEffect(.degrees(-8))
                    .offset(x: -proxy.size.width * 0.12, y: proxy.size.height * 0.27)
                Capsule()
                    .fill(Theme.Palette.crush.opacity(0.09))
                    .frame(width: proxy.size.width * 1.28, height: 96)
                    .rotationEffect(.degrees(7))
                    .offset(x: proxy.size.width * 0.08, y: proxy.size.height * 0.33)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
