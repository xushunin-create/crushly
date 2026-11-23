import SwiftUI

/// Me › Privacy & safety: pause, permission guidance, notifications, blocked users, what's stored, account deletion.
struct PrivacySettingsView: View {
    @Environment(AppState.self) private var state
    @State private var showPause = false
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                if state.isPausedNow {
                    LabeledContent("Status", value: pausedText)
                    AsyncButton { await state.perform { try await state.resumeCampusMatching() } } label: {
                        Label("Resume campus matching", systemImage: "play.circle")
                    }
                    .accessibilityIdentifier("privacy.resume")
                } else {
                    Button { showPause = true } label: {
                        Label("Pause campus matching", systemImage: "pause.circle")
                    }
                    .accessibilityIdentifier("privacy.pause")
                }
                if state.campusMatchingOn {
                    AsyncButton { await state.turnOffCampusMatching() } label: {
                        Label("Stop checking my location", systemImage: "location.slash")
                    }
                } else {
                    AsyncButton { await state.turnOnCampusMatching() } label: {
                        Label("Turn on campus matching", systemImage: "location")
                    }
                }
            } header: { Text("Campus matching") } footer: {
                Text("Pausing makes you invisible right away and ends any matching session; nobody is told. Resuming never makes you visible by itself.")
            }

            Section {
                LabeledContent("Location access", value: permissionText)
                switch state.locationAuthorization {
                case .denied:
                    Button("Open Settings") { openSettings() }
                case .approximate:
                    Button("Allow precise location for now") { state.requestPreciseLocation() }
                    Button("Open Settings") { openSettings() }
                case .notDetermined, .precise:
                    EmptyView()
                }
            } header: { Text("Location") } footer: {
                Text("Crushly only uses location While Using the App. It never asks for Always access. Approximate location can't tell which campus space you're in.")
            }

            Section("Alerts and people") {
                NavigationLink("Notifications") { NotificationSettingsView() }
                NavigationLink("Blocked people") { BlockedListView() }
                NavigationLink("How matching works") { HowMatchingWorksView() }
                NavigationLink("Safety tips") { SafetyTipsView() }
            }

            Section("What Crushly keeps") {
                fact("Your location stays on your iPhone. While you're open to matching, the server knows only which space you chose, for up to 60 seconds after your last renewal.")
                fact("No history of where you've been: sessions and interests are deleted when they end.")
                fact("Messages are encrypted in transit and at rest but are not end-to-end encrypted. Crushly's operators can technically read them.")
                fact("Messages you choose as evidence in a report are kept for up to 90 days for safety review.")
                fact("Deleted data can remain in encrypted backups until they age out.")
            }

            Section {
                Button("Delete account and data", role: .destructive) { confirmDelete = true }
                    .accessibilityIdentifier("privacy.delete")
            } footer: {
                Text("Ends any matching session, deletes your profile, photos, matches and messages, and removes this iPhone's message cache.")
            }
        }
        .foregroundStyle(Theme.Palette.ink, Theme.Palette.inkSoft)
        .navigationTitle("Privacy & safety")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPause) { PauseSheet().presentationDetents([.medium, .large]) }
        .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) {
                Task { await state.perform { try await state.deleteAccount() } }
            }
        } message: {
            Text("Your profile, photos, matches, messages and settings are deleted from Crushly's active systems. Reports involving you may be kept for safety review, and backups age out on their own schedule.")
        }
    }

    private var pausedText: String {
        if let until = state.participation?.pausedUntil { return "Paused until \(until.formatted(date: .abbreviated, time: .shortened))" }
        return "Paused until you resume"
    }

    private var permissionText: String {
        switch state.locationAuthorization {
        case .notDetermined: "Not asked yet"
        case .denied: "Off"
        case .approximate: "Approximate"
        case .precise: "While using the app"
        }
    }

    private func fact(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.shield")
            .font(Theme.Typeface.subheadline)
            .foregroundStyle(Theme.Palette.ink)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// Shown over the app whenever it isn't active (app switcher, Control Center), so chats and profiles never appear
/// in the system snapshot.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            RetroBackground()
            VStack(spacing: Theme.Space.l) {
                CrushlyBrandIcon(size: 84)
                Text("Crushly").font(Theme.Typeface.display).foregroundStyle(Theme.Palette.oxblood)
            }
        }
        .accessibilityHidden(true)
    }
}
