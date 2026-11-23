import SwiftUI

/// Spaces: your own status first, then (only while you're open to matching) the people you could match with here.
/// Never shows anyone's location, distance, arrival, status or counts.
struct SpacesView: View {
    @Environment(AppState.self) private var state
    @State private var selected: PublicProfile?
    @State private var showDesignPreview = false
    @State private var showMatchPreview = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header
                StatusCard()
                if state.config.isDemo { demoPreviewControls }
                if state.profile?.photoReviewStatus == .rejected { rejectedPhotoCard }
                if state.shouldOfferNotifications { NotificationPrimerCard() }
                if state.isParticipating { participatingContent }
                SupportedSpacesSection()
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.top, Theme.Space.s)
            .crushScrollPadding()
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await state.reconcileParticipation()
            await state.refreshDiscovery(force: true)
            await state.refreshReceipts()
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $selected) { person in PersonProfileView(person: person) }
        .sheet(isPresented: $showDesignPreview) { DemoDesignPreviewView() }
        .fullScreenCover(isPresented: $showMatchPreview) {
            HeartSyncRevealView(match: DemoMotionPreview.match, previewMode: true)
        }
    }

    private var header: some View {
        ScreenHeading(
            title: "Spaces",
            subtitle: "Campus matching, on your terms.",
            trailing: state.config.isDemo ? AnyView(DemoBadge()) : nil
        )
        .padding(.top, Theme.Space.s)
    }

    private var rejectedPhotoCard: some View {
        Label("Your photo wasn't approved, so you can't match until you add a new one in Me › Edit profile.",
              systemImage: "exclamationmark.triangle.fill")
            .font(Theme.Typeface.subheadline.weight(.semibold))
            .foregroundStyle(Theme.Palette.danger)
            .crushCard(fill: Theme.Palette.crushSoft)
    }

    private var demoPreviewControls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Label("Design previews", systemImage: "play.circle.fill")
                    .font(Theme.Typeface.headline)
                    .foregroundStyle(Theme.Palette.oxblood)
                Spacer()
                DemoBadge()
            }
            Text("View the radar and motion design without entering a matching space. Nothing here changes your demo matches.")
                .font(Theme.Typeface.footnote)
                .foregroundStyle(Theme.Palette.inkSoft)
            HStack(spacing: Theme.Space.s) {
                Button("Radar + send") { showDesignPreview = true }
                    .buttonStyle(.crush(.secondary))
                Button("Match animation") { showMatchPreview = true }
                    .buttonStyle(.crush)
            }
        }
        .crushCard(fill: Theme.Palette.blush.opacity(0.24))
        .accessibilityIdentifier("demo.designPreviews")
    }

    @ViewBuilder private var participatingContent: some View {
        if state.interestReceipts > 0 {
            Label(state.interestReceipts == 1 ? "Someone here is interested" : "People here are interested",
                  systemImage: "heart.fill")
                .font(Theme.Typeface.headline)
                .foregroundStyle(Theme.Palette.crushText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .crushCard(fill: Theme.Palette.blush.opacity(0.35))
                .accessibilityIdentifier("spaces.receipt")
        }

        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "People you could match with")
                Spacer()
                if let remaining = state.interestsRemaining {
                    Text("\(remaining) interests left")
                        .font(Theme.Typeface.caption.weight(.bold))
                        .foregroundStyle(Theme.Palette.inkSoft)
                }
            }
            switch state.discoveryState {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, Theme.Space.xl)
                    .accessibilityLabel("Loading")
            case .quiet:
                EmptyStateView(symbol: "leaf", title: "It's quiet here",
                               message: "Not enough people are open to matching here right now. Stay open and check back in a bit.")
                    .accessibilityIdentifier("spaces.quiet")
            case .ready:
                if state.candidates.isEmpty {
                    EmptyStateView(symbol: "sparkles", title: "No one new right now",
                                   message: "Pull down to check again in a moment.")
                } else {
                    RadarPeopleField(candidates: state.candidates, sentInterestIDs: state.sentInterests) {
                        selected = $0
                    }
                }
            }
        }
    }
}

/// A playful discovery surface for profiles already returned by `discoverCandidates()`.
/// The visual positions are deterministic from profile IDs, never from location or distance.
private struct RadarPeopleField: View {
    let candidates: [PublicProfile]
    let sentInterestIDs: Set<UUID>
    let select: (PublicProfile) -> Void

    @State private var scanAngle = -105.0

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)

                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                        .fill(Theme.Palette.crushSoft.opacity(0.18))

                    radarGrid(side: side)
                        .position(center)

                    ForEach(candidates) { person in
                        RadarPersonButton(
                            person: person,
                            sentInterest: sentInterestIDs.contains(person.id),
                            action: { select(person) }
                        )
                        .position(position(for: person, in: proxy.size, radarSide: side))
                    }

                    HeartMark(size: 25)
                        .frame(width: 64, height: 64)
                        .background(Theme.Palette.surface, in: Circle())
                        .overlay(Circle().stroke(Theme.Palette.crush.opacity(0.45), lineWidth: 2))
                        .shadow(color: Theme.Palette.crush.opacity(0.2), radius: 10, y: 4)
                        .position(center)
                        .accessibilityLabel("You")
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
            }
            .frame(height: 350)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("People you could match with radar")

            Text("Tap a profile to learn more. Interest stays private unless it’s mutual.")
                .font(Theme.Typeface.footnote)
                .foregroundStyle(Theme.Palette.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func radarGrid(side: CGFloat) -> some View {
        ZStack {
            ForEach([0.26, 0.50, 0.74, 0.96], id: \.self) { fraction in
                Circle()
                    .stroke(Theme.Palette.crush.opacity(fraction == 0.96 ? 0.25 : 0.14), lineWidth: 1)
                    .frame(width: side * fraction, height: side * fraction)
            }
            Path { path in
                path.move(to: CGPoint(x: 0, y: side / 2))
                path.addLine(to: CGPoint(x: side, y: side / 2))
                path.move(to: CGPoint(x: side / 2, y: 0))
                path.addLine(to: CGPoint(x: side / 2, y: side))
            }
            .stroke(Theme.Palette.crush.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))

            Circle()
                .fill(
                    AngularGradient(
                        colors: [.clear, Theme.Palette.crush.opacity(0.22), .clear],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(65)
                    )
                )
                .rotationEffect(.degrees(scanAngle))
                .frame(width: side * 0.96, height: side * 0.96)
                .mask(alignment: .top) { Rectangle().frame(height: side / 2) }
        }
        .frame(width: side, height: side)
        .onAppear {
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                scanAngle = 255
            }
        }
    }

    private func position(for person: PublicProfile, in size: CGSize, radarSide: CGFloat) -> CGPoint {
        let seed = stableSeed(for: person.id)
        let angle = Double(seed % 360) * .pi / 180
        // Keep every avatar away from the center, with uneven rings for a natural, non-grid layout.
        let radius = radarSide * (0.18 + Double((seed / 360) % 19) / 100)
        let offset = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        return CGPoint(x: size.width / 2 + offset.x, y: size.height / 2 + offset.y)
    }

    private func stableSeed(for id: UUID) -> UInt64 {
        id.uuidString.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ UInt64($1) }
    }
}

private struct RadarPersonButton: View {
    let person: PublicProfile
    let sentInterest: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Avatar(path: person.photoPaths.first, name: person.firstName, size: 54)
                    .overlay(Circle().stroke(Theme.Palette.surface, lineWidth: 3))
                    .shadow(color: Theme.Palette.oxblood.opacity(0.16), radius: 6, y: 3)
                    .overlay(alignment: .bottomTrailing) {
                        if sentInterest {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(Theme.Palette.crush, in: Circle())
                                .overlay(Circle().stroke(Theme.Palette.surface, lineWidth: 2))
                        }
                    }
                Text(person.firstName)
                    .font(Theme.Typeface.caption.weight(.bold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Theme.Palette.surface.opacity(0.92), in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sentInterest ? "\(person.firstName), interest sent" : person.firstName)
        .accessibilityHint("Opens profile")
        .accessibilityIdentifier("candidate.\(person.firstName)")
    }
}

/// Demo-only surface that renders the shipping radar and hold-to-send control without a participation session.
private struct DemoDesignPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var previewSent = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    Text("Radar preview")
                        .font(Theme.Typeface.title)
                        .foregroundStyle(Theme.Palette.oxblood)
                    Text("These fictional profiles exist only to preview the layout and motion.")
                        .font(Theme.Typeface.callout)
                        .foregroundStyle(Theme.Palette.inkSoft)
                    RadarPeopleField(candidates: DemoMotionPreview.people, sentInterestIDs: []) { _ in }
                    Divider()
                    Text("Send animation")
                        .font(Theme.Typeface.title2)
                        .foregroundStyle(Theme.Palette.oxblood)
                    InterestButton(person: DemoMotionPreview.people[0], justSent: $previewSent, previewMode: true)
                    if previewSent {
                        Button("Play again") { previewSent = false }
                            .buttonStyle(.crush(.secondary))
                    }
                }
                .padding(Theme.Space.gutter)
            }
            .background(Theme.Palette.paper)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private enum DemoMotionPreview {
    static let people: [PublicProfile] = [
        person("0F0D20B1-8B6A-4B6D-9AA1-000000000001", "Mina", 21, "avatar:heart.fill|purple"),
        person("0F0D20B1-8B6A-4B6D-9AA1-000000000002", "Theo", 22, "avatar:star.fill|blue"),
        person("0F0D20B1-8B6A-4B6D-9AA1-000000000003", "Ava", 20, "avatar:sun.max.fill|orange"),
        person("0F0D20B1-8B6A-4B6D-9AA1-000000000004", "Sam", 23, "avatar:music.note|mint"),
        person("0F0D20B1-8B6A-4B6D-9AA1-000000000005", "Noor", 21, "avatar:sparkles|teal")
    ]

    static let match = Conversation(
        id: UUID(uuidString: "0F0D20B1-8B6A-4B6D-9AA1-000000000099")!,
        createdAt: .now,
        other: people[0],
        lastMessageAt: nil,
        lastMessagePreview: nil,
        lastMessageFromMe: nil,
        unread: false
    )

    private static func person(_ id: String, _ name: String, _ age: Int, _ avatar: String) -> PublicProfile {
        PublicProfile(
            id: UUID(uuidString: id)!, firstName: name, age: age, pronouns: "", gender: "",
            interests: [], vibeTags: [], promptQuestion: "", promptAnswer: "", intention: .figuringItOut,
            availability: .either, photoPaths: [avatar], photoReviewStatus: .approved
        )
    }
}

/// The user's own status, always first and prominent.
struct StatusCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Label(title, systemImage: symbol)
                .font(Theme.Typeface.title2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("status.title")
            Text(message)
                .font(Theme.Typeface.callout)
                .opacity(0.9)
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .inkCard(padding: Theme.Space.xl)
        .accessibilityElement(children: .contain)
    }

    private var status: AppState.SpacesStatus { state.spacesStatus }

    private var title: String {
        switch status {
        case .off, .invisibleHere, .checking: "Invisible"
        case .needsPermission(.permissionDenied): "Location is off for Crushly"
        case .needsPermission(.approximateLocation): "Precise location needed"
        case .needsPermission: "Invisible"
        case .paused: "Campus matching paused"
        case .outside: "Outside supported spaces"
        case .awaitingChoice: "Space detected, awaiting your choice"
        case .participating: "Open to matching during this visit"
        case .unverified: "Matching paused, location could not be verified"
        }
    }

    private var symbol: String {
        switch status {
        case .participating: "heart.fill"
        case .awaitingChoice: "questionmark.circle.fill"
        case .unverified: "exclamationmark.triangle.fill"
        case .paused: "pause.circle.fill"
        case .needsPermission: "location.slash.fill"
        default: "eye.slash.fill"
        }
    }

    private var message: String {
        switch status {
        case .off:
            "Turn on campus matching and Crushly will privately check, while the app is open, whether you're in a supported campus space. You're invisible until you choose otherwise."
        case .needsPermission(.permissionDenied):
            "Crushly needs location While Using the App to tell whether you're in a campus space. Your precise location is never shown to anyone."
        case .needsPermission(.approximateLocation):
            "Approximate location can be off by miles, so Crushly can't tell whether you're in a campus space."
        case .needsPermission:
            "Allow location While Using the App so Crushly can check whether you're in a supported campus space."
        case .paused(let until):
            if let until { "You're invisible until \(until.formatted(date: .omitted, time: .shortened)). Nothing changes until then." }
            else { "You're invisible until you turn campus matching back on." }
        case .outside:
            "You're invisible. When you're in a supported campus space, you'll be asked whether to match there."
        case .checking(let name):
            "Checking whether you're in \(name). You're invisible."
        case .awaitingChoice(let name):
            "You're at \(name). You're invisible until you choose."
        case .invisibleHere(let name):
            "You're at \(name) and chose to stay invisible for this visit."
        case .participating(let name):
            state.renewalTrouble
                ? "At \(name). Reconnecting… if this doesn't recover within a minute you'll become invisible."
                : "At \(name). People here who are also open to matching can see your profile. Your location is never shown."
        case .unverified(let name):
            "Crushly can't confirm you're still in \(name), so you'll become invisible within a minute unless it can."
        }
    }

    @ViewBuilder private var actions: some View {
        switch status {
        case .off:
            AsyncButton { await state.turnOnCampusMatching() } label: { Text("Turn on campus matching") }
                .buttonStyle(.crush(.onInk))
                .accessibilityIdentifier("status.turnOn")
        case .needsPermission(.permissionDenied):
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.crush(.onInk))
        case .needsPermission(.approximateLocation):
            Button("Allow precise location for now") { state.requestPreciseLocation() }
                .buttonStyle(.crush(.onInk))
        case .needsPermission:
            AsyncButton { await state.turnOnCampusMatching() } label: { Text("Allow location") }
                .buttonStyle(.crush(.onInk))
        case .paused:
            AsyncButton { await state.perform { try await state.resumeCampusMatching() } } label: { Text("Resume campus matching") }
                .buttonStyle(.crush(.onInk))
                .accessibilityIdentifier("status.resume")
        case .awaitingChoice, .invisibleHere:
            AsyncButton { await state.openToMatching() } label: { Text("Open to matching here") }
                .buttonStyle(.crush(.onInk))
                .accessibilityIdentifier("status.open")
        case .participating, .unverified:
            AsyncButton { await state.goInvisible() } label: { Label("Go invisible", systemImage: "eye.slash") }
                .buttonStyle(.crush(.onInk))
                .accessibilityIdentifier("status.goInvisible")
        case .outside, .checking:
            EmptyView()
        }
    }
}
