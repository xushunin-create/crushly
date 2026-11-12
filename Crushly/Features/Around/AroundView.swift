import SwiftUI

/// Around: your Pulse status, then the people active in your Campus Space (radar or list).
struct AroundView: View {
    @Environment(AppState.self) private var state
    @State private var mode: DisplayMode = .radar
    @State private var showStartSheet = false
    @State private var selected: PublicProfile?
    @State private var editingPhotos = false

    enum DisplayMode: String, CaseIterable { case radar = "Radar", list = "List" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header
                if state.pulseState != .live { pulseHero }
                PulseStatusCard(showStart: $showStartSheet)
                if state.profile?.photoReviewStatus == .rejected { rejectedPhotoCard }
                if state.shouldOfferNotifications { NotificationPrimerCard() }

                if state.pulseState == .live {
                    liveContent
                } else if !state.recent.isEmpty && !state.isShielded {
                    recentSection
                }
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, Theme.Space.xl)
        }
        .refreshable { await state.reloadAccount() }
        .background(Color.clear)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showStartSheet) { StartPulseSheet() }
        .sheet(item: $selected) { person in PersonProfileView(person: person) }
        .sheet(isPresented: $editingPhotos) {
            NavigationStack { ProfileEditorView(mode: .edit) }.closesForReveal()
        }
        .task { await state.refreshSocial() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "person.crop.circle")
                .font(.title2)
                .foregroundStyle(Theme.Palette.oxblood)
                .frame(width: Theme.minTap, height: Theme.minTap)
            Spacer()
            Text(state.pulseState == .live ? "Around" : "Crushly")
                .font(Theme.Typeface.title2)
                .foregroundStyle(Theme.Palette.oxblood)
            Spacer()
            Group {
                if state.config.isDemo {
                    DemoBadge()
                } else {
                    Image(systemName: "bell")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.Palette.oxblood)
                }
            }
            .frame(minWidth: Theme.minTap, minHeight: Theme.minTap)
        }
    }

    private var pulseHero: some View {
        VStack(spacing: Theme.Space.m) {
            ZStack {
                SparkRays().offset(y: -26)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(Theme.Palette.crush)
            }
            Text("Pulse Mode")
                .font(Theme.Typeface.display)
                .foregroundStyle(Theme.Palette.oxblood)
            Text("Go on campus. Be visible.\nMeet real crushes.")
                .font(Theme.Typeface.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.inkSoft)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
        .background(Theme.Palette.blush.opacity(0.22), in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(Theme.Palette.orange.opacity(0.24))
                .frame(width: 92, height: 92)
                .offset(x: 26, y: 34)
                .clipped()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var liveContent: some View {
        HStack {
            Text(peopleCountText)
                .font(Theme.Typeface.headline)
            Spacer()
            Picker("View", selection: $mode) {
                ForEach(DisplayMode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
        }

        if state.around.isEmpty {
            EmptyStateView(
                symbol: "heart.circle",
                title: "Quiet right now",
                message: "No one else is active in \(state.currentSpace?.name ?? "this space") yet. Stay visible or try another space."
            )
            .crushCard()
        } else if mode == .radar {
            RadarView(people: state.around, seed: state.pulse?.id ?? UUID()) { selected = $0 }
                .frame(height: 360)
            Text("Positions on the radar are decorative and don't reflect where anyone is.")
                .font(Theme.Typeface.footnote)
                .foregroundStyle(Theme.Palette.inkSoft)
        } else {
            LazyVStack(spacing: Theme.Space.m) {
                ForEach(state.around) { person in
                    Button { selected = person } label: { PersonRow(person: person) }
                        .buttonStyle(.plain)
                }
            }
        }

        if !state.recent.isEmpty { recentSection }
    }

    /// A rejected photo hides you from everyone (server: hide_rejected_photos), so say so plainly.
    private var rejectedPhotoCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Label("Your photo wasn't approved", systemImage: "xmark.octagon.fill")
                .font(Theme.Typeface.headline)
                .foregroundStyle(Theme.Palette.danger)
            Text("Others can't see you until you add a new photo. New photos go back into review.")
                .font(Theme.Typeface.subheadline)
                .foregroundStyle(Theme.Palette.inkSoft)
            Button("Update photos") { editingPhotos = true }
                .buttonStyle(.crush(.secondary))
                .accessibilityIdentifier("photo.rejected.update")
        }
        .crushCard(fill: Theme.Palette.crushSoft.opacity(0.6))
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Eyebrow(text: "Recently in your radius")
            Text("People you crossed paths with in the last \(state.rules.encounterWindowHours) hours. A signal still counts.")
                .font(Theme.Typeface.footnote)
                .foregroundStyle(Theme.Palette.inkSoft)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.m) {
                    ForEach(state.recent) { person in
                        Button { selected = person } label: {
                            VStack(spacing: 6) {
                                Avatar(path: person.photoPaths.first, name: person.firstName, size: 64)
                                Text(person.firstName).font(Theme.Typeface.caption.weight(.bold)).foregroundStyle(Theme.Palette.ink)
                            }
                            .frame(minWidth: 72)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(person.firstName), recently nearby")
                    }
                }
            }
        }
    }

    private var peopleCountText: String {
        let count = state.around.count
        let place = state.currentSpace?.name ?? "here"
        return count == 1 ? "1 person in \(place)" : "\(count) people in \(place)"
    }
}

// MARK: - Notification primer

/// Non-modal, shown after the first Heart Signal — the moment a notification is clearly useful.
struct NotificationPrimerCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Label("Know the moment it's mutual", systemImage: "bell.badge.fill")
                .font(Theme.Typeface.headline)
                .foregroundStyle(Theme.Palette.crush)
            Text("We'll only nudge you about signals, matches and meetups. Lock-screen alerts never show names or photos.")
                .font(Theme.Typeface.subheadline)
                .foregroundStyle(Theme.Palette.inkSoft)
            HStack(spacing: Theme.Space.s) {
                AsyncButton { await state.enableNotifications() } label: { Text("Turn on") }
                    .buttonStyle(.crush)
                    .accessibilityIdentifier("notifications.enable")
                Button("Not now") { withAnimation(Theme.Motion.soft) { state.dismissNotificationPrimer() } }
                    .buttonStyle(.crush(.secondary))
                    .accessibilityIdentifier("notifications.notNow")
            }
        }
        .crushCard(padding: Theme.Space.l)
    }
}

// MARK: - Person row (List view)

struct PersonRow: View {
    let person: PublicProfile

    var body: some View {
        HStack(spacing: Theme.Space.l) {
            Avatar(path: person.photoPaths.first, name: person.firstName, size: 68, shape: .rounded)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("\(person.firstName), \(person.age)").font(Theme.Typeface.headline)
                    VerificationBadge(status: person.photoReviewStatus)
                }
                Label(availabilityLine, systemImage: person.availability.symbol)
                .font(Theme.Typeface.caption)
                .foregroundStyle(Theme.Palette.inkSoft)
                if !person.vibeTags.isEmpty {
                    Text(person.vibeTags.prefix(2).joined(separator: " · "))
                        .font(Theme.Typeface.caption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.plum)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(Theme.Palette.inkFaint).accessibilityHidden(true)
        }
        .crushCard(padding: Theme.Space.m)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens profile")
    }

    private var availabilityLine: String {
        if let band = person.simulatedDistanceBand { return "\(person.availability.title) · \(band) (simulated)" }
        if let space = person.spaceName { return "\(person.availability.title) · \(space)" }
        return person.availability.title
    }
}

/// Only shown when the photo review status is actually `approved`.
struct VerificationBadge: View {
    let status: ReviewStatus
    var body: some View {
        if status == .approved {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Theme.Palette.mint)
                .accessibilityLabel("Photos approved")
        }
    }
}
