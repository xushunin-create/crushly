import SwiftUI

/// Spaces: your own status first, then (only while you're open to matching) the people you could match with here.
/// Never shows anyone's location, distance, arrival, status or counts.
struct SpacesView: View {
    @Environment(AppState.self) private var state
    @State private var selected: PublicProfile?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header
                StatusCard()
                if state.profile?.photoReviewStatus == .rejected { rejectedPhotoCard }
                if state.shouldOfferNotifications { NotificationPrimerCard() }
                if state.isParticipating { participatingContent }
                SupportedSpacesSection()
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, Theme.Space.xl)
        }
        .refreshable {
            await state.reconcileParticipation()
            await state.refreshDiscovery(force: true)
            await state.refreshReceipts()
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $selected) { person in PersonProfileView(person: person) }
    }

    private var header: some View {
        HStack {
            Text("Spaces")
                .font(Theme.Typeface.title)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(Theme.Palette.oxblood)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if state.config.isDemo { DemoBadge() }
        }
        .frame(minHeight: Theme.minTap)
    }

    private var rejectedPhotoCard: some View {
        Label("Your photo wasn't approved, so you can't match until you add a new one in Me › Edit profile.",
              systemImage: "exclamationmark.triangle.fill")
            .font(Theme.Typeface.subheadline.weight(.semibold))
            .foregroundStyle(Theme.Palette.danger)
            .crushCard(fill: Theme.Palette.crushSoft)
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
                    ForEach(state.candidates) { person in
                        Button { selected = person } label: {
                            PersonRow(person: person, detail: state.sentInterests.contains(person.id) ? "Interest sent privately" : nil)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens profile")
                        .accessibilityIdentifier("candidate.\(person.firstName)")
                    }
                    Text("A different few each time. Interest stays private unless it's mutual.")
                        .font(Theme.Typeface.footnote)
                        .foregroundStyle(Theme.Palette.inkSoft)
                }
            }
        }
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
