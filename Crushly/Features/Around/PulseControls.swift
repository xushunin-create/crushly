import SwiftUI

/// The status card at the top of Around. Makes visible / paused / expired / protected unmistakable,
/// and always shows the next available action.
struct PulseStatusCard: View {
    @Environment(AppState.self) private var state
    @Binding var showStart: Bool
    @State private var showShield = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date.addingTimeInterval(state.clockSkew)
            content(now: now)
        }
        .sheet(isPresented: $showShield) { ShieldSheet().presentationDetents([.medium]) }
    }

    private var shieldShortcut: some View {
        Button { showShield = true } label: {
            Label("Protect My Heart", systemImage: "shield.lefthalf.filled")
                .font(Theme.Typeface.subheadline.weight(.bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, minHeight: Theme.minTap)
        }
        .accessibilityHint("Hides you immediately and ends your session")
    }

    @ViewBuilder private func content(now: Date) -> some View {
        if state.isShielded {
            card(tint: Theme.Palette.lavender, icon: "shield.lefthalf.filled", eyebrow: "Protect My Heart",
                 title: "You're hidden", detail: shieldDetail(now: now)) {
                AsyncButton { await state.perform { try await state.exitShield() } } label: { Text("Leave Protect My Heart") }
                    .buttonStyle(.crush(.onInk))
            }
        } else if let session = state.pulse {
            switch session.state(at: now) {
            case .live:
                card(tint: Theme.Palette.live, icon: "dot.radiowaves.left.and.right", eyebrow: "Visible",
                     title: state.currentSpace?.name ?? "Pulse is live",
                     detail: "\(format(session.remaining(at: now))) left · \(session.availability.title) · \(state.signalsRemaining) of \(state.rules.signalsPerSession) signals left") {
                    HStack(spacing: Theme.Space.s) {
                        AsyncButton { await state.perform { try await state.pausePulse() } } label: { Label("Pause", systemImage: "pause.fill") }
                            .buttonStyle(.crush(.onInk))
                            .accessibilityIdentifier("pulse.pause")
                        AsyncButton { await state.perform { try await state.endPulse() } } label: { Text("Turn off") }
                            .buttonStyle(.crush(.onInk))
                            .accessibilityIdentifier("pulse.off")
                    }
                    shieldShortcut
                }
            case .paused:
                card(tint: Theme.Palette.amber, icon: "pause.circle.fill", eyebrow: "Paused · hidden",
                     title: state.currentSpace?.name ?? "Paused",
                     detail: "No one can see you. Session still ends in \(format(session.remaining(at: now))).") {
                    HStack(spacing: Theme.Space.s) {
                        AsyncButton { await state.perform { try await state.resumePulse() } } label: { Label("Resume", systemImage: "play.fill") }
                            .buttonStyle(.crush)
                            .accessibilityIdentifier("pulse.resume")
                        AsyncButton { await state.perform { try await state.endPulse() } } label: { Text("Turn off") }
                            .buttonStyle(.crush(.onInk))
                    }
                    shieldShortcut
                }
            case .expired, .ended:
                expiredCard
            }
        } else if state.sessionExpiredNotice {
            expiredCard
        } else {
            offCard(title: "You're not visible", detail: "Only people who enter the radius can see each other.")
        }
    }

    private var expiredCard: some View {
        card(tint: Theme.Palette.amberSoft, icon: "clock.badge.xmark", eyebrow: "Session ended", title: "Time's up — you're hidden",
             detail: "Your Pulse ran out, so no one can see you. Signals you sent stay valid for \(state.rules.signalValidityHours) hours.") {
            Button { showStart = true } label: { Label("Enter the Radius again", systemImage: "heart.fill") }
                .buttonStyle(.crush)
        }
    }

    private func offCard(title: String, detail: String) -> some View {
        card(tint: .white.opacity(0.6), icon: "eye.slash", eyebrow: "Off", title: title, detail: detail) {
            Button { showStart = true } label: { Label("Enter the Radius", systemImage: "heart.fill") }
                .buttonStyle(.crush)
                .accessibilityIdentifier("pulse.start")
        }
    }

    private func card<Actions: View>(tint: Color, icon: String, eyebrow: String, title: String, detail: String,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: icon).foregroundStyle(tint).accessibilityHidden(true)
                Text(eyebrow.uppercased()).font(Theme.Typeface.eyebrow).tracking(1.6).foregroundStyle(tint)
            }
            Text(title).font(Theme.Typeface.title2)
            Text(detail).font(Theme.Typeface.subheadline).foregroundStyle(.white.opacity(0.75))
                .monospacedDigit()
            actions()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .inkCard(padding: Theme.Space.xl)
        .accessibilityElement(children: .contain)
    }

    private func shieldDetail(now: Date) -> String {
        guard let until = state.shield?.activeUntil else { return "Until you turn it off. Signals and discovery are paused." }
        return "For \(format(until.timeIntervalSince(now))). Leaving won't make you visible — you'll choose when."
    }
}

func format(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval))
    let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return String(format: "%d:%02d", minutes, seconds)
}

/// Enter the Radius: choose a Campus Space, duration and availability.
struct StartPulseSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var spaceID: UUID?
    @State private var duration: DurationChoice = .minutes(30)
    @State private var availability: Availability = .either
    @State private var code = ""

    enum DurationChoice: Hashable { case minutes(Int), eventEnd }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    Text("Pick where you are. People only see others in the same Campus Space.")
                        .font(Theme.Typeface.callout).foregroundStyle(Theme.Palette.inkSoft)

                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        Eyebrow(text: "Campus Space")
                        ForEach(state.spaces) { space in spaceRow(space) }
                        HStack {
                            TextField("Event code", text: $code)
                                .accessibilityIdentifier("pulse.code")
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .padding(.horizontal, Theme.Space.l)
                                .frame(minHeight: 50)
                                .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                            AsyncButton {
                                if let space = try? await state.enterSpaceCode(code) {
                                    spaceID = space.id
                                    code = ""
                                } else {
                                    state.handle(CrushlyError.invalidCode)
                                }
                            } label: { Text("Join") }
                                .buttonStyle(.crush(.ink))
                                .frame(width: 96)
                                .disabled(code.count < 4)
                        }
                        if state.config.isDemo {
                            Text("Demo codes: IYA2026, HACKSC").font(Theme.Typeface.footnote).foregroundStyle(Theme.Palette.plum)
                        }
                    }

                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        Eyebrow(text: "How long")
                        HStack(spacing: Theme.Space.s) {
                            ForEach(state.rules.pulseDurationsMinutes, id: \.self) { minutes in
                                durationButton(.minutes(minutes), title: "\(minutes) min")
                            }
                            if let space = selectedSpace, space.hasFutureEnd(now: state.now()), let end = space.endsAt {
                                durationButton(.eventEnd, title: "Until \(end.formatted(date: .omitted, time: .shortened))")
                            }
                        }
                        Text("Pausing hides you immediately but doesn't stop the clock.")
                            .font(Theme.Typeface.footnote).foregroundStyle(Theme.Palette.inkSoft)
                    }

                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        Eyebrow(text: "Right now I'm up for")
                        AvailabilityPicker(selection: $availability)
                    }

                    AsyncButton { await start() } label: { Label("Enter the Radius", systemImage: "heart.fill") }
                        .buttonStyle(.crush)
                        .accessibilityIdentifier("pulse.confirmStart")
                        .disabled(spaceID == nil)
                }
                .padding(Theme.Space.gutter)
            }
            .background(Theme.Palette.paper)
            .navigationTitle("Enter the Radius")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .closesForReveal()
        .task {
            if state.spaces.isEmpty { await state.loadSpaces() }
            availability = state.profile?.availability ?? .either
            let preferred = UserDefaults.standard.integer(forKey: PulseDefaults.durationKey)
            if state.rules.pulseDurationsMinutes.contains(preferred) { duration = .minutes(preferred) }
        }
        .onChange(of: spaceID) { _, _ in
            if duration == .eventEnd, selectedSpace?.hasFutureEnd(now: state.now()) != true { duration = .minutes(30) }
        }
    }

    private var selectedSpace: CampusSpace? { state.spaces.first { $0.id == spaceID } }

    private func spaceRow(_ space: CampusSpace) -> some View {
        let selected = spaceID == space.id
        return Button { spaceID = space.id; state.feedback.play(.tap) } label: {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: space.symbol)
                    .frame(width: 40, height: 40)
                    .background(selected ? Theme.Palette.crush : Theme.Palette.crushSoft, in: Circle())
                    .foregroundStyle(selected ? .white : Theme.Palette.crush)
                VStack(alignment: .leading, spacing: 2) {
                    Text(space.name).font(Theme.Typeface.headline)
                    Text(space.subtitle).font(Theme.Typeface.caption).foregroundStyle(Theme.Palette.inkSoft)
                }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Palette.crush) }
            }
            .foregroundStyle(Theme.Palette.ink)
            .crushCard(padding: Theme.Space.m, fill: selected ? Theme.Palette.crushSoft.opacity(0.5) : Theme.Palette.surface)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func durationButton(_ choice: DurationChoice, title: String) -> some View {
        SelectableChip(title: title, selected: duration == choice, tint: Theme.Palette.ink) { duration = choice }
    }

    private func start() async {
        guard let spaceID else { return }
        let ok = await state.perform {
            switch duration {
            case .minutes(let minutes):
                try await state.startPulse(spaceID: spaceID, durationMinutes: minutes, untilEventEnd: false, availability: availability)
            case .eventEnd:
                try await state.startPulse(spaceID: spaceID, durationMinutes: nil, untilEventEnd: true, availability: availability)
            }
        }
        if ok { dismiss() }
    }
}
