import SwiftUI

struct PersonProfileView: View {
    let person: PublicProfile

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var showSafety = false
    @State private var justSent = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Space.xl) {
                    HeartSignalButton(person: person, justSent: $justSent)
                        .padding(.top, Theme.Space.s)
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
    }

    private var identity: some View {
        VStack(spacing: Theme.Space.s) {
            HStack(spacing: 8) {
                Text("\(person.firstName), \(person.age)").font(Theme.Typeface.display)
                VerificationBadge(status: person.photoReviewStatus)
            }
            Text([person.pronouns, person.gender].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(Theme.Typeface.callout).foregroundStyle(Theme.Palette.inkSoft)
            HStack(spacing: Theme.Space.s) {
                StatusPill(text: person.availability.title, systemImage: person.availability.symbol,
                           tint: Theme.Palette.ink, fill: Theme.Palette.surface)
                if let band = person.simulatedDistanceBand {
                    StatusPill(text: "\(band) · simulated", systemImage: "testtube.2", tint: Theme.Palette.plum, fill: Theme.Palette.plumSoft)
                } else if let space = person.spaceName {
                    StatusPill(text: space, systemImage: "mappin.circle", tint: Theme.Palette.ink, fill: Theme.Palette.surface)
                }
            }
        }
        .multilineTextAlignment(.center)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if !person.promptAnswer.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(person.promptQuestion).font(Theme.Typeface.subheadline.weight(.bold)).foregroundStyle(Theme.Palette.crush)
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

/// The central Send Heart Signal control: heartbeat, expanding signal rings, sound + haptics on success.
struct HeartSignalButton: View {
    let person: PublicProfile
    @Binding var justSent: Bool

    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beating = false
    @State private var ringsOut = false
    @State private var sending = false

    private enum Availability { case canSend, sent, matched, limit, notLive, shielded }

    private var availability: Availability {
        if state.match(with: person.id) != nil { return .matched }
        if justSent || state.hasPendingSignal(to: person.id) { return .sent }
        if state.isShielded { return .shielded }
        if state.pulseState != .live { return .notLive }
        if state.signalsRemaining == 0 { return .limit }
        return .canSend
    }

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Button(action: send) { heart }
                .buttonStyle(.plain)
                .disabled(availability != .canSend || sending)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(availability == .canSend ? "Sends an anonymous Heart Signal" : "")

            Text(caption)
                .font(Theme.Typeface.callout)
                .foregroundStyle(Theme.Palette.inkSoft)
                .multilineTextAlignment(.center)
                .frame(minHeight: 44)
                .animation(Theme.Motion.soft, value: caption)
        }
        .onAppear { beating = true }
    }

    private var heart: some View {
        let sent = availability == .sent || availability == .matched
        let active = availability == .canSend || sent
        return ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(Theme.Palette.crush.opacity(0.3 - Double(index) * 0.08), lineWidth: 2)
                    .frame(width: CGFloat(190 + index * 44), height: CGFloat(190 + index * 44))
                    .scaleEffect(ringsOut ? 1.25 : 0.7)
                    .opacity(ringsOut ? 0 : (sent || reduceMotion ? 0 : 0.6))
            }
            Circle()
                .fill(Theme.Palette.crush.opacity(sent ? 0.18 : 0.1))
                .frame(width: 210, height: 210)
            Circle()
                .fill(LinearGradient(
                    colors: active ? [Theme.Palette.crush, Color(red: 0.62, green: 0.05, blue: 0.24)] : [Color.gray.opacity(0.5), Color.gray.opacity(0.35)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 158, height: 158)
                .shadow(color: Theme.Palette.crush.opacity(sent ? 0.5 : 0.22), radius: sent ? 26 : 10)
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
                    .frame(width: 130)
            }
            .foregroundStyle(.white)
        }
        .frame(width: 300, height: 300)
        .scaleEffect(reduceMotion ? 1 : (beating ? 1.035 : 0.965))
        .animation(reduceMotion ? nil : Theme.Motion.heartbeat, value: beating)
        .animation(.easeOut(duration: 1.15), value: ringsOut)
    }

    private var buttonTitle: String {
        switch availability {
        case .canSend: "SEND HEART SIGNAL"
        case .sent: "SIGNAL SENT"
        case .matched: "IT'S MUTUAL"
        case .limit: "NO SIGNALS LEFT"
        case .notLive: "ENTER THE RADIUS FIRST"
        case .shielded: "PROTECTED"
        }
    }

    private var caption: String {
        switch availability {
        case .canSend: "Anonymous unless they feel it too. \(state.signalsRemaining) left this session."
        case .sent: "Sent privately. If they signal you too, you'll both know."
        case .matched: "You noticed each other. Find them in Signals."
        case .limit: "You've used all \(state.rules.signalsPerSession) signals this session."
        case .notLive: "Start a Pulse session to send signals."
        case .shielded: "Leave Protect My Heart to send signals."
        }
    }

    private var accessibilityLabel: String { buttonTitle.capitalized }

    private func send() {
        guard availability == .canSend, !sending else { return }
        sending = true
        Task {
            do {
                let result = try await state.sendHeartSignal(to: person)
                sending = false
                justSent = true
                if case .sent = result {
                    ringsOut = false
                    try? await Task.sleep(for: .milliseconds(40))
                    ringsOut = true
                }
            } catch {
                sending = false
                state.handle(error)
            }
        }
    }
}
