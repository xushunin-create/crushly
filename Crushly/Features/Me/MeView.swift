import SwiftUI

struct MeView: View {
    @Environment(AppState.self) private var state
    @State private var verifiedOnly = false
    @State private var sounds = FeedbackService.shared.soundsEnabled
    @State private var legal: TermsView.LegalDoc?

    var body: some View {
        List {
            Section {
                profileCard
                NavigationLink("Edit profile & matching preferences") { ProfileEditorView(mode: .edit) }
            }

            Section {
                NavigationLink { PrivacySettingsView() } label: {
                    Label(state.isPausedNow ? "Privacy & safety · matching paused" : "Privacy & safety", systemImage: "hand.raised.square")
                }
                .accessibilityIdentifier("me.privacy")
            } footer: {
                Text("Pause campus matching, location access, notifications, blocked people and account deletion.")
            }

            Section("Discovery") {
                Toggle(isOn: $verifiedOnly) {
                    VStack(alignment: .leading) {
                        Text("Verified profiles only")
                        Text("Only see — and be seen by — people whose photos are approved.")
                            .font(Theme.Typeface.footnote).foregroundStyle(Theme.Palette.inkSoft)
                    }
                }
                .onChange(of: verifiedOnly) { _, value in
                    guard value != state.account.verifiedOnlyDiscovery else { return }
                    Task { await state.perform { try await state.saveVerifiedOnly(value) } }
                }
            }

            Section {
                NavigationLink("Notifications") { NotificationSettingsView() }
                Toggle("Sounds", isOn: $sounds)
                    .onChange(of: sounds) { _, value in FeedbackService.shared.soundsEnabled = value }
            } header: { Text("Alerts") }

            Section("Legal") {
                Button("Terms of Service") { legal = .terms }
                Button("Privacy Policy") { legal = .privacy }
            }

            Section("Account") {
                LabeledContent("Email", value: state.email)
                LabeledContent("Email status", value: "Verified (USC)")
                Button("Sign out") { Task { await state.signOut() } }
            }

            if state.demo != nil { DemoControlsSection() }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.paper)
        .foregroundStyle(Theme.Palette.ink, Theme.Palette.inkSoft)   // section headers/footers readable on paper
        .navigationTitle("Me")
        .sheet(item: $legal) { doc in LegalDocumentView(kind: doc) }
        .onAppear { verifiedOnly = state.account.verifiedOnlyDiscovery }
    }

    private var profileCard: some View {
        HStack(spacing: Theme.Space.l) {
            Avatar(path: state.profile?.photoPaths.first, name: state.profile?.firstName ?? "", size: 72)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(state.profile?.firstName ?? ""), \(state.profile?.age ?? 18)").font(Theme.Typeface.title2)
                ReviewStatusPill(status: state.profile?.photoReviewStatus ?? .pending, hasPhotos: !(state.profile?.photoPaths.isEmpty ?? true))
                Text("Selfie verification: not available yet").font(Theme.Typeface.caption).foregroundStyle(Theme.Palette.inkSoft)
            }
        }
        .padding(.vertical, Theme.Space.s)
        .accessibilityElement(children: .combine)
    }
}

struct SafetyTipsView: View {
    var body: some View {
        List {
            Section("Meeting someone") {
                tip("person.3.fill", "Meet in public", "If you decide to meet, pick a busy, well-lit spot on campus.")
                tip("message.fill", "Tell a friend", "Share where you're going and who you're meeting.")
                tip("figure.walk.departure", "Leave whenever you want", "You never owe anyone a meetup. You can leave a conversation at any time.")
                tip("car.fill", "Get yourself there and back", "Use your own transport, or a route you know.")
            }
            Section("In the app") {
                tip("pause.circle", "Pause campus matching", "Become invisible instantly and end any matching session. No one is told.")
                tip("hand.raised.fill", "Block", "Ends any conversation. They can't match or message you, and aren't notified.")
                tip("exclamationmark.bubble.fill", "Report", "Reports are private and reviewed by the Crushly team. Reporting also blocks.")
                tip("location.slash.fill", "Your location stays on your phone", "Crushly never shares your coordinates, distance, direction or movements. People matching in the same space can infer you were there too.")
            }
            Section {
                Label("In an emergency, call 911.", systemImage: "phone.fill")
                    .font(Theme.Typeface.callout.weight(.bold))
                    .foregroundStyle(Theme.Palette.danger)
                Text("Save USC Department of Public Safety's number in your phone before you go out.")
                    .font(Theme.Typeface.footnote)
            }
        }
        .foregroundStyle(Theme.Palette.ink, Theme.Palette.inkSoft)   // section headers/footers readable on paper
        .navigationTitle("Safety tips")
    }

    private func tip(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: icon).foregroundStyle(Theme.Palette.crush).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Typeface.headline)
                Text(detail).font(Theme.Typeface.subheadline).foregroundStyle(Theme.Palette.inkSoft)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct PauseSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text("You'll become invisible right away and any matching session ends. Nobody is notified. Resuming never makes you visible on its own: you'll be asked again in a space.")
                    .font(Theme.Typeface.callout).foregroundStyle(Theme.Palette.inkSoft)
                ForEach(Array((state.rules.pauseDurationsMinutes.map(Optional.some) + [nil]).enumerated()), id: \.offset) { _, minutes in
                    AsyncButton {
                        if await state.perform({ try await state.pauseCampusMatching(minutes: minutes) }) { dismiss() }
                    } label: { Text(label(minutes)) }
                        .buttonStyle(.crush(.ink))
                }
                Spacer()
            }
            .padding(Theme.Space.gutter)
            .navigationTitle("Pause campus matching")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .closesForReveal()
    }

    private func label(_ minutes: Int?) -> String {
        guard let minutes else { return "Until I turn it back on" }
        return minutes < 60 ? "\(minutes) minutes" : (minutes == 60 ? "1 hour" : "\(minutes / 60) hours")
    }
}

struct BlockedListView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        List {
            if state.blocked.isEmpty {
                Text("You haven't blocked anyone.").foregroundStyle(Theme.Palette.inkSoft)
            }
            ForEach(state.blocked) { person in
                HStack {
                    VStack(alignment: .leading) {
                        Text(person.firstName).font(Theme.Typeface.headline)
                        Text("Blocked \(person.blockedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(Theme.Typeface.caption).foregroundStyle(Theme.Palette.inkSoft)
                    }
                    Spacer()
                    AsyncButton { await state.perform { try await state.unblock(person.id) } } label: { Text("Unblock") }
                        .buttonStyle(.crush(.quiet))
                        .frame(width: 120)
                }
            }
        }
        .foregroundStyle(Theme.Palette.ink, Theme.Palette.inkSoft)   // section headers/footers readable on paper
        .navigationTitle("Blocked")
        .task { await state.loadBlocked() }
    }
}

struct NotificationSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Form {
            Section {
                switch state.notificationPermission {
                case .allowed:
                    Label("Notifications are on", systemImage: "bell.fill")
                case .denied:
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Notifications are off for Crushly", systemImage: "bell.slash.fill")
                        Text("Turn them on in Settings to hear about matches. The app works without them.")
                            .font(Theme.Typeface.footnote).foregroundStyle(Theme.Palette.inkSoft)
                    }
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                case .notDetermined:
                    AsyncButton { await state.enableNotifications() } label: { Text("Turn on notifications") }
                }
            }
            Section {
                toggle("New matches", \.newMatches)
                toggle("Messages", \.messages)
            } footer: {
                Text("Lock-screen alerts only say \"You have a new match.\" or \"You have a new message.\" No names, photos, places or message text. Your choices are enforced on the server, so they apply on every device.")
            }
        }
        .foregroundStyle(Theme.Palette.ink, Theme.Palette.inkSoft)   // section headers/footers readable on paper
        .navigationTitle("Notifications")
        .task { await state.refreshNotificationPermission() }
    }

    private func toggle(_ title: String, _ key: WritableKeyPath<NotificationPrefs, Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { state.prefs[keyPath: key] },
            set: { value in
                var prefs = state.prefs
                prefs[keyPath: key] = value
                Task { await state.updatePrefs(prefs) }
            }
        ))
    }
}

/// Demo-only controls. Hidden when `state.demo` is nil, so they never exist in live mode.
struct DemoControlsSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Section {
            if let sim = state.simulatedLocation {
                Picker("Simulated location", selection: Binding(
                    get: { sim.place },
                    set: { state.demoMove(to: $0) })) {
                    Text("Outside supported spaces").tag(SimulatedLocationProvider.Place.outside)
                    ForEach(state.zones) { zone in
                        Text(zone.name).tag(SimulatedLocationProvider.Place.zone(zone.slug))
                    }
                }
                .accessibilityIdentifier("demo.location")
                Picker("Simulated permission", selection: Binding(
                    get: { sim.authorization },
                    set: { state.demoSetLocationAuthorization($0) })) {
                    Text("Precise").tag(LocationAuthorization.precise)
                    Text("Approximate").tag(LocationAuthorization.approximate)
                    Text("Denied").tag(LocationAuthorization.denied)
                    Text("Not asked yet").tag(LocationAuthorization.notDetermined)
                }
            }
            Button("Skip ahead 2 minutes (lets the lease lapse)") { Task { await state.demoSkipAhead(minutes: 2) } }
            Button("Skip ahead 1 hour") { Task { await state.demoSkipAhead(minutes: 60) } }
            Button("Simulate photo approval") { Task { await state.demoSimulateReview(.approved) } }
            Button("Simulate photo rejection") { Task { await state.demoSimulateReview(.rejected) } }
            DisclosureGroup("Scenario cast") {
                ForEach(state.demo?.scenarioNotes ?? [], id: \.name) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(Theme.Typeface.headline)
                        Text(item.note).font(Theme.Typeface.footnote).foregroundStyle(Theme.Palette.inkSoft)
                    }
                }
            }
        } header: {
            HStack { Text("Demo controls"); DemoBadge() }
        } footer: {
            Text("Dev fixture: fictional people, a simulated location and a simulated clock. Draft spaces are allowed here only. Nothing is saved or sent anywhere.")
        }
    }
}
