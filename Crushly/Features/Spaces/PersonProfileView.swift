import SwiftUI

/// A profile opened from Spaces (with the interest button) or from a conversation (`showsInterest: false`).
struct PersonProfileView: View {
    let person: PublicProfile
    var showsInterest = true

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var showSafety = false
    @State private var justSent = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Space.xl) {
                    if showsInterest {
                        InterestButton(person: person, justSent: $justSent)
                            .padding(.top, Theme.Space.s)
                    }
                    identity
                    details
                }
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.bottom, Theme.Space.xxl)
            }
            .background(Theme.Palette.paper)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showSafety = true } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("Safety options")
                }
            }
            .sheet(isPresented: $showSafety) {
                SafetyActionsSheet(person: person) { dismiss() }
                    .presentationDetents([.medium, .large])
            }
        }
        .closesForReveal()
    }

    private var identity: some View {
        VStack(spacing: Theme.Space.s) {
            HStack(spacing: 8) {
                Text("\(person.firstName), \(person.age)").font(Theme.Typeface.display)
                VerificationBadge(status: person.photoReviewStatus)
            }
            Text([person.pronouns, person.gender].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(Theme.Typeface.callout).foregroundStyle(Theme.Palette.inkSoft)
            StatusPill(text: person.availability.title, systemImage: person.availability.symbol,
                       tint: Theme.Palette.ink, fill: Theme.Palette.surface)
        }
        .multilineTextAlignment(.center)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if !person.promptAnswer.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(person.promptQuestion).font(Theme.Typeface.subheadline.weight(.bold)).foregroundStyle(Theme.Palette.crushText)
                    Text(person.promptAnswer).font(Theme.Typeface.title2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .crushCard(padding: Theme.Space.xl)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Eyebrow(text: "Into")
                FlowLayout(spacing: 8) { ForEach(person.interests, id: \.self) { Tag(text: $0) } }
            }
            if !person.vibeTags.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Eyebrow(text: "Vibe")
                    FlowLayout(spacing: 8) {
                        ForEach(person.vibeTags, id: \.self) { Tag(text: $0, tint: Theme.Palette.plum, fill: Theme.Palette.plumSoft) }
                    }
                }
            }
            Label(person.intention.title, systemImage: "heart.text.square")
                .font(Theme.Typeface.callout.weight(.semibold))
            if person.photoReviewStatus != .approved {
                Text("Photos not yet reviewed.").font(Theme.Typeface.footnote).foregroundStyle(Theme.Palette.inkSoft)
            }
        }
    }
}

/// Keeps the "sent" heart vivid; the default styles dim disabled buttons, which reads as broken here.
private struct UndimmedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.Motion.snappy, value: configuration.isPressed)
    }
}

/// Private interest is deliberately a hold-to-send action, so a like feels intentional rather than accidental.
struct InterestButton: View {
    let person: PublicProfile
    @Binding var justSent: Bool

    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beating = false
    @State private var popped = false
    @State private var sending = false
    @State private var isPressing = false
    @State private var isCharged = false
    @State private var chargeProgress = 0.0

    private enum Availability { case canSend, sent, matched, limit, notParticipating }

    private var availability: Availability {
        if state.conversations.contains(where: { $0.other.id == person.id }) { return .matched }
        if justSent || state.sentInterests.contains(person.id) { return .sent }
        if !state.isParticipating { return .notParticipating }
        if state.interestsRemaining == 0 { return .limit }
        return .canSend
    }

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Button(action: {}) { heart }
                .buttonStyle(UndimmedButtonStyle())
                .disabled(availability != .canSend || sending)
                .simultaneousGesture(holdToSend)
                .accessibilityLabel(buttonTitle.capitalized)
                .accessibilityHint(availability == .canSend ? "Hold for a moment, then lift your finger to send privately" : "")
                .accessibilityAction(.default) { send() }
                .accessibilityIdentifier("interest.send")

            Text(caption)
                .font(Theme.Typeface.callout)
                .foregroundStyle(Theme.Palette.inkSoft)
                .multilineTextAlignment(.center)
                .frame(minHeight: 44)
                .animation(Theme.Motion.soft, value: caption)
                .accessibilityIdentifier("interest.caption")
        }
        .onAppear { beating = true }
    }

    private var heart: some View {
        let sent = availability == .sent || availability == .matched
        let active = availability == .canSend || sent
        return ZStack {
            Circle()
                .stroke(Theme.Palette.crush.opacity(isPressing ? 0.42 : (sent ? 0.28 : 0.12)), lineWidth: isPressing ? 5 : 1)
                .frame(width: 210, height: 210)
                .scaleEffect(isPressing ? 1.06 : 1)

            if isPressing && !reduceMotion {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .stroke(Theme.Palette.crush.opacity(0.36 - Double(index) * 0.09), lineWidth: 2)
                        .frame(width: 170 + CGFloat(index * 20), height: 170 + CGFloat(index * 20))
                        .scaleEffect(chargeProgress > 0.75 ? 1.06 : 0.94)
                        .opacity(chargeProgress > 0.75 ? 1 : 0.38)
                }
            }
            Circle()
                .fill(LinearGradient(
                    colors: active ? [Theme.Palette.crush, Color(red: 0.62, green: 0.05, blue: 0.24)] : [Color.gray.opacity(0.5), Color.gray.opacity(0.35)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 158, height: 158)
                .shadow(color: Theme.Palette.crush.opacity(sent ? 0.5 : 0.22), radius: sent ? 26 : 10)
                .overlay {
                    if availability == .canSend {
                        Circle()
                            .trim(from: 0, to: chargeProgress)
                            .stroke(.white.opacity(0.92), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(7)
                    }
                }
            VStack(spacing: 8) {
                if sending {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: availability == .matched ? "heart.circle.fill" : "heart.fill")
                        .font(.system(size: 50, weight: .bold))
                }
                Text(buttonTitle)
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .tracking(1)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                    .frame(width: 136)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            }
            .foregroundStyle(.white)

            if sent {
                Image(systemName: "heart.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.Palette.crush)
                    .padding(11)
                    .background(Theme.Palette.surface, in: Circle())
                    .offset(y: -112)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: 240, height: 240)
        .scaleEffect(reduceMotion ? 1 : (beating ? 1.035 : 0.965) * (popped ? 1.08 : 1) * (isPressing ? 0.97 : 1))
        .animation(reduceMotion ? nil : Theme.Motion.heartbeat, value: beating)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.5), value: popped)
    }

    private var buttonTitle: String {
        switch availability {
        case .canSend:
            if sending { "SENDING…" }
            else if isCharged { "RELEASE TO SEND" }
            else if isPressing { "KEEP HOLDING" }
            else { "HOLD TO SEND" }
        case .sent: "INTEREST SENT"
        case .matched: "IT'S MUTUAL"
        case .limit: "NO INTERESTS LEFT"
        case .notParticipating: "NOT OPEN TO MATCHING"
        }
    }

    private var caption: String {
        switch availability {
        case .canSend:
            if isCharged { "Release when you’re ready. Your interest stays private unless it’s mutual." }
            else { "Hold to send privately.\(state.interestsRemaining.map { " \($0) left this visit." } ?? "")" }
        case .sent: "Sent privately. If they're interested too, you'll both know."
        case .matched: "You're matched. Say hi in Connections."
        case .limit: "You've used all \(state.rules.interestsPerSession) interests for this visit."
        case .notParticipating: "Choose \"Open to matching\" in this space to show interest."
        }
    }

    private var holdToSend: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in beginCharging() }
            .onEnded { _ in finishCharging() }
    }

    private func beginCharging() {
        guard availability == .canSend, !sending, !isPressing else { return }
        isPressing = true
        isCharged = false
        chargeProgress = 0
        withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.6)) { chargeProgress = 1 }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, isPressing else { return }
            isCharged = true
        }
    }

    private func finishCharging() {
        isPressing = false
        guard isCharged else {
            isCharged = false
            withAnimation(Theme.Motion.soft) { chargeProgress = 0 }
            return
        }
        send()
    }

    private func send() {
        guard availability == .canSend, !sending else { return }
        isPressing = false
        isCharged = false
        chargeProgress = 0
        sending = true
        Task {
            do {
                let result = try await state.expressInterest(in: person)
                sending = false
                justSent = true
                if case .sent = result {
                    popped = true
                    try? await Task.sleep(for: .milliseconds(250))
                    popped = false
                }
            } catch {
                sending = false
                state.handle(error)
            }
        }
    }
}
