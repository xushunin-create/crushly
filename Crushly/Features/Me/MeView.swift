import SwiftUI

struct MeView: View {
    @Environment(AppState.self) private var state
    @State private var showShield = false
    @State private var confirmDelete = false
    @State private var verifiedOnly = false
    @State private var sounds = FeedbackService.shared.soundsEnabled
    @AppStorage(PulseDefaults.durationKey) private var defaultDuration = 30

    var body: some View {
        List {
            Section {
                profileCard
                NavigationLink("Edit profile") { ProfileEditorView(mode: .edit) }
            }

            Section {
                if state.isShielded {
                    AsyncButton { await state.perform { try await state.exitShield() } } label: {
                        Label("Leave Protect My Heart", systemImage: "shield.slash")
                    }
                } else {
                    Button { showShield = true } label: {
                        Label("Protect My Heart", systemImage: "shield.lefthalf.filled")
                            .foregroundStyle(Theme.Palette.plum)
                    }
                }
                if state.pulse != nil {
                    AsyncButton { await state.perform { try await state.endPulse() } } label: {
                        Label("Turn off Pulse and exit space", systemImage: "eye.slash")
                    }
                }
            } header: { Text("Safety") } footer: {
                Text("Protect My Heart hides you immediately, ends your session and pauses signals. No one is told.")
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
                    Task { await state.perform { try await state.savePrivate(instagram: state.account.instagramHandle, verifiedOnly: value) } }
                }
                LabeledContent("Discovery range", value: "Campus Space")
                Text("Distance-based discovery isn't available yet. You only see people in the same Campus Space.")
                    .font(Theme.Typeface.footnote).foregroundStyle(Theme.Palette.inkSoft)
            }

            Section {
                Picker("Default session length", selection: $defaultDuration) {
                    ForEach(state.rules.pulseDurationsMinutes, id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Picker("Default availability", selection: Binding(
                    get: { state.profile?.availability ?? .either },
                    set: { value in
                        guard var profile = state.profile, profile.availability != value else { return }
                        profile.availability = value
                        Task { await state.perform { try await state.saveProfile(profile) } }
                    }
                )) {
                    ForEach(Availability.allCases) { Text($0.title).tag($0) }
                }
            } header: { Text("Pulse") } footer: {
                Text("Used when you Enter the Radius. You can change both each time.")
            }

            Section {
                NavigationLink("Notifications") { NotificationSettingsView() }
                Toggle("Sounds", isOn: $sounds)
                    .onChange(of: sounds) { _, value in FeedbackService.shared.soundsEnabled = value }
            } header: { Text("Alerts") }

            Section("Privacy") {
                NavigationLink("Safety tips") { SafetyTipsView() }
                NavigationLink("Blocked people") { BlockedListView() }
                Button("Terms of Service") { legal = .terms }
                Button("Privacy Policy") { legal = .privacy }
            }

            Section("Account") {
                LabeledContent("Email", value: state.email)
                LabeledContent("Email status", value: "Verified (USC)")
                Button("Sign out") { Task { await state.signOut() } }
                Button("Delete account and data", role: .destructive) { confirmDelete = true }
            }

            if state.demo != nil { DemoControlsSection() }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.paper)
        .foregroundStyle(Theme.Palette.ink, Theme.Palette.inkSoft)   // section headers/footers readable on paper
        .navigationTitle("Me")
        .sheet(isPresented: $showShield) { ShieldSheet().presentationDetents([.medium]) }
        .sheet(item: $legal) { doc in LegalDocumentView(title: doc.rawValue) }
        .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) {
                Task { await state.perform { try await state.deleteAccount() } }
            }
        } message: {
            Text("Your profile, photos, signals, matches and settings are deleted. Reports involving you may be kept for safety review.")
        }
        .onAppear { verifiedOnly = state.account.verifiedOnlyDiscovery }
    }

    @State private var legal: TermsView.LegalDoc?

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

enum PulseDefaults {
    static let durationKey = "crushly.defaultDuration"
}

struct SafetyTipsView: View {
    var body: some View {
        List {
            Section("Meeting someone") {
                tip("person.3.fill", "Meet in public", "Pick a busy, well-lit spot on campus — the preset meeting points are all public.")
                tip("message.fill", "Tell a friend", "Share where you're going and who you're meeting.")
                tip("figure.walk.departure", "Leave whenever you want", "You never owe anyone a meetup. Cancel Find Mode anytime.")
                tip("car.fill", "Get yourself there and back", "Use your own transport, or a route you know.")
            }
            Section("In the app") {
                tip("shield.lefthalf.filled", "Protect My Heart", "Disappear instantly, end your session and stop all signals. No one is told.")
                tip("hand.raised.fill", "Block", "They can't see, signal or interact with you, and aren't notified.")
                tip("exclamationmark.bubble.fill", "Report", "Reports are private and reviewed by the Crushly team. Reporting also blocks.")
                tip("location.slash.fill", "No live location", "Crushly never shares your coordinates, direction or movements.")
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

struct ShieldSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text("You'll disappear from Around right away, your session ends, active meetups are cancelled, and no new signals come in or go out. Nobody is notified.")
                    .font(Theme.Typeface.callout).foregroundStyle(Theme.Palette.inkSoft)
                ForEach(Array(state.rules.shieldDurationsMinutes.enumerated()), id: \.offset) { _, minutes in
                    AsyncButton {
                        if await state.perform({ try await state.enterShield(minutes: minutes) }) { dismiss() }
                    } label: { Text(label(minutes)) }
                        .buttonStyle(.crush(.ink))
                }
                Spacer()
            }
            .padding(Theme.Space.gutter)
            .navigationTitle("Protect My Heart")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .closesForReveal()
    }

    private func label(_ minutes: Int?) -> String {
        guard let minutes else { return "Until I turn it off" }
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
                toggle("Anonymous Heart Signals", \.anonymousSignals)
                toggle("Heart Sync", \.heartSync)
                toggle("Crossed Hearts", \.crossedHearts)
                toggle("Meeting requests", \.findRequests)
                toggle("Connect Later reminders", \.connectionReminders)
                toggle("Connection expiring", \.connectionExpiry)
                toggle("Pulse session ending", \.pulseExpiry)
                toggle("Campus events", \.campusEvents)
            } footer: {
                Text("Lock-screen alerts never include names, photos or places. Your choices are enforced on the server, so they apply on every device.")
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

/// Demo-only controls. Never compiled into behaviour for live mode (hidden when `state.demo` is nil).
struct DemoControlsSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Section {
            Button("Skip ahead 5 minutes") { Task { await state.demoSkipAhead(minutes: 5) } }
            Button("Skip ahead 30 minutes") { Task { await state.demoSkipAhead(minutes: 30) } }
            Button("Skip ahead 25 hours") { Task { await state.demoSkipAhead(minutes: 25 * 60) } }
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
            Text("Fictional people, simulated moderation and a simulated clock. Nothing here is saved or sent anywhere.")
        }
    }
}
