import SwiftUI

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

/// Non-modal, shown after the first interest or match — the moment a notification is clearly useful.
struct NotificationPrimerCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Label("Know when it's mutual", systemImage: "bell.badge.fill")
                .font(Theme.Typeface.headline)
                .foregroundStyle(Theme.Palette.crushText)
            Text("We'll only tell you about new matches and messages. Lock-screen alerts never show names, photos or places.")
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

/// Compact profile card used for candidates and conversations. Never shows place, distance or activity.
struct PersonRow: View {
    let person: PublicProfile
    var detail: String?
    var showsChevron = true

    var body: some View {
        HStack(spacing: Theme.Space.l) {
            Avatar(path: person.photoPaths.first, name: person.firstName, size: 68, shape: .rounded)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("\(person.firstName), \(person.age)").font(Theme.Typeface.headline).foregroundStyle(Theme.Palette.ink)
                    VerificationBadge(status: person.photoReviewStatus)
                }
                Text(detail ?? person.intention.title)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                if detail == nil, !person.vibeTags.isEmpty {
                    Text(person.vibeTags.prefix(2).joined(separator: " · "))
                        .font(Theme.Typeface.caption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.plum)
                }
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right").foregroundStyle(Theme.Palette.inkFaint).accessibilityHidden(true)
            }
        }
        .crushCard(padding: Theme.Space.m)
        .accessibilityElement(children: .combine)
    }
}
