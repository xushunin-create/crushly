import SwiftUI

/// Around: your Pulse status, then the people active in your Campus Space (radar or list).
struct AroundView: View {
    @Environment(AppState.self) private var state
    @State private var mode: DisplayMode = .radar
    @State private var showStartSheet = false
    @State private var selected: PublicProfile?

    enum DisplayMode: String, CaseIterable { case radar = "Radar", list = "List" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header
                PulseStatusCard(showStart: $showStartSheet)

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
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showStartSheet) { StartPulseSheet() }
        .sheet(item: $selected) { person in PersonProfileView(person: person) }
        .task { await state.refreshSocial() }
    }

    private var header: some View {
        SectionHeader(
            eyebrow: state.currentSpace.map { "In \($0.name)" } ?? "Surrounding you",
            title: "Your radius",
            trailing: state.config.isDemo ? AnyView(DemoBadge()) : nil
        )
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
