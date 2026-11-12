import SwiftUI

/// Full-screen mutual match reveal. Covers the tab bar so the moment has focus.
struct HeartSyncRevealView: View {
    let match: Match

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var together = false
    @State private var pulse = false
    @State private var showFind = false
    @State private var savedForLater = false

    private var isSync: Bool { match.kind == .heartSync }

    var body: some View {
        ZStack {
            RetroBackground()

            VStack(spacing: Theme.Space.xl) {
                Spacer(minLength: Theme.Space.l)
                Text(isSync ? "Heart Sync" : "Crossed Hearts")
                    .font(Theme.Typeface.title)
                    .foregroundStyle(Theme.Palette.oxblood)

                portraits

                VStack(spacing: Theme.Space.s) {
                    if savedForLater {
                        Text("The timing isn't right yet.").font(Theme.Typeface.title)
                        Text("Your connection is saved for later.").font(Theme.Typeface.title2).foregroundStyle(Theme.Palette.inkSoft)
                    } else if isSync {
                        Text("You noticed\neach other").font(Theme.Typeface.display)
                        Text("The feeling is mutual.").font(Theme.Typeface.title2).foregroundStyle(Theme.Palette.crush)
                    } else {
                        Text("You missed the moment,").font(Theme.Typeface.title)
                        Text("not each other.").font(Theme.Typeface.title2).foregroundStyle(Theme.Palette.inkSoft)
                    }
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.Palette.oxblood)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("reveal.headline")

                Spacer(minLength: Theme.Space.l)

                VStack(spacing: Theme.Space.m) {
                    if savedForLater {
                        Button("Done") { dismiss() }.buttonStyle(.crush)
                    } else {
                        if isSync && state.pulseState == .live {
                            Button { showFind = true } label: { Label("Find Each Other Now", systemImage: "figure.walk") }
                                .buttonStyle(.crush)
                                .accessibilityIdentifier("reveal.find")
                        }
                        AsyncButton {
                            await state.setConnection(match, status: .findLater)
                            withAnimation(Theme.Motion.soft) { savedForLater = true }
                        } label: { Text("Connect Later") }
                            .accessibilityIdentifier("reveal.later")
                            .buttonStyle(.crush(.secondary))
                        Button("Stay in the Moment") { dismiss() }
                            .accessibilityIdentifier("reveal.stay")
                            .font(Theme.Typeface.button)
                            .foregroundStyle(Theme.Palette.inkSoft)
                            .frame(minHeight: Theme.minTap)
                    }
                }
            }
            .padding(Theme.Space.gutter)
        }
        .sheet(isPresented: $showFind) {
            FindRequestSheet(match: match) { dismiss() }
                .presentationDetents([.medium, .large])
        }
        .onAppear {
            withAnimation(reduceMotion ? .none : .spring(response: 0.8, dampingFraction: 0.65).delay(0.15)) { together = true }
            if !reduceMotion { pulse = true }
            UIAccessibility.post(notification: .announcement, argument: isSync ? "Heart Sync. The feeling is mutual." : "Crossed Hearts.")
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
        .frame(height: 300)
        .accessibilityElement()
        .accessibilityLabel("You and \(match.other.firstName)")
    }
}
