import SwiftUI

struct SignalsView: View {
    @Environment(AppState.self) private var state
    @State private var mutedNotice = false

    private var heartSyncs: [Match] { state.activeMatches.filter { $0.kind == .heartSync } }
    private var crossed: [Match] { state.activeMatches.filter { $0.kind == .crossedHearts } }
    private var expired: [Match] { state.matches.filter { $0.connection.status == .expired } }
    private var pendingSent: [SentSignal] { state.sentSignals.filter { $0.status == .pending && $0.expiresAt > state.now() } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                SectionHeader(eyebrow: "Signals", title: "Who felt it")

                noticedSection

                if state.matches.isEmpty && state.receipts.isEmpty {
                    EmptyStateView(symbol: "heart.text.square", title: "Nothing yet",
                                   message: "When someone signals you, it shows up here anonymously. Mutual signals become matches.")
                        .crushCard()
                }

                matchSection("Matched", subtitle: "Heart Sync — you were in the same moment.", matches: heartSyncs)
                matchSection("Crossed Hearts", subtitle: "You missed the moment, not each other.", matches: crossed)

                if !pendingSent.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        Eyebrow(text: "Your signals")
                        Text("\(pendingSent.count) waiting. They stay anonymous unless it's mutual, and expire after \(state.rules.signalValidityHours) hours.")
                            .font(Theme.Typeface.subheadline).foregroundStyle(Theme.Palette.inkSoft)
                    }
                }

                if !expired.isEmpty {
                    matchSection("Expired", subtitle: "These connections ran out of time.", matches: expired)
                }
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.vertical, Theme.Space.s)
        }
        .refreshable { await state.refreshSocial() }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: UUID.self) { id in MatchDetailView(matchID: id) }
        .task { await state.refreshSocial() }
    }

    @ViewBuilder private var noticedSection: some View {
        if !state.receipts.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HStack {
                    Image(systemName: "heart.fill").font(.title2).foregroundStyle(Theme.Palette.crush)
                    Spacer()
                    Text("\(state.receipts.count)")
                        .font(.system(.title, design: .serif).weight(.bold))
                        .foregroundStyle(Theme.Palette.live)
                }
                Text("Someone nearby noticed you.")
                    .font(Theme.Typeface.title2)
                ForEach(state.receipts) { receipt in
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "sparkle").foregroundStyle(Theme.Palette.crush).accessibilityHidden(true)
                        Text(receiptText(receipt)).font(Theme.Typeface.subheadline)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                }
                Text("We never show who. Signal them back from Around and, if it's them, you'll both know.")
                    .font(Theme.Typeface.footnote).foregroundStyle(.white.opacity(0.65))
                HStack(spacing: Theme.Space.s) {
                    Button("Explore Around") { state.selectedTab = .around }
                        .buttonStyle(.crush)
                        .accessibilityIdentifier("receipts.explore")
                    Button("Not Right Now") { withAnimation(Theme.Motion.soft) { state.dismissReceipts() } }
                        .buttonStyle(.crush(.onInk))
                        .accessibilityIdentifier("receipts.notNow")
                }
                Menu {
                    Button("Mute for 1 hour") { Task { await state.muteSignalAlerts(hours: 1) } }
                    Button("Mute for 8 hours") { Task { await state.muteSignalAlerts(hours: 8) } }
                    Button("Mute for 24 hours") { Task { await state.muteSignalAlerts(hours: 24) } }
                } label: {
                    Label("Mute anonymous signal alerts", systemImage: "bell.slash")
                        .font(Theme.Typeface.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity, minHeight: Theme.minTap)
                }
                if let until = state.prefs.signalsMutedUntil, until > state.now() {
                    Text("Signal alerts muted until \(until.formatted(date: .omitted, time: .shortened)).")
                        .font(Theme.Typeface.footnote).foregroundStyle(.white.opacity(0.65))
                }
            }
            .inkCard(padding: Theme.Space.xl)
            .accessibilityElement(children: .contain)
        }
    }

    /// Deliberately coarse, matching the server's 15-minute buckets, so timing can't identify the sender.
    private func receiptText(_ receipt: SignalReceipt) -> String {
        let age = state.now().timeIntervalSince(receipt.receivedBucket)
        let time: String
        if age < 15 * 60 { time = "In the last 15 minutes" }
        else if age < 3600 { time = "Within the last hour" }
        else if Calendar.current.isDateInToday(receipt.receivedBucket) { time = "Earlier today" }
        else if Calendar.current.isDateInYesterday(receipt.receivedBucket) { time = "Yesterday" }
        else { time = "A few days ago" }
        if let space = receipt.spaceName { return "\(time) · \(space)" }
        return time
    }

    @ViewBuilder private func matchSection(_ title: String, subtitle: String, matches: [Match]) -> some View {
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Eyebrow(text: title)
                Text(subtitle).font(Theme.Typeface.footnote).foregroundStyle(Theme.Palette.inkSoft)
                ForEach(matches) { match in
                    NavigationLink(value: match.id) { MatchRow(match: match) }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}

struct MatchRow: View {
    let match: Match
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: Theme.Space.l) {
            Avatar(path: match.other.photoPaths.first, name: match.other.firstName, size: 60)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: match.kind == .heartSync ? "heart.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, match.kind == .heartSync ? Theme.Palette.crush : Theme.Palette.plum)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(match.other.firstName).font(Theme.Typeface.headline)
                Text(statusLine).font(Theme.Typeface.caption).foregroundStyle(Theme.Palette.inkSoft)
                if let deadline = match.connection.deadline {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text("Expires \(deadline.formatted(.relative(presentation: .named)))")
                            .font(Theme.Typeface.caption.weight(.semibold))
                            .foregroundStyle(Theme.Palette.amber)
                    }
                }
            }
            Spacer()
            if needsResponse { Circle().fill(Theme.Palette.crush).frame(width: 10, height: 10).accessibilityLabel("Needs your response") }
            Image(systemName: "chevron.right").foregroundStyle(Theme.Palette.inkFaint).accessibilityHidden(true)
        }
        .crushCard(padding: Theme.Space.m)
        .accessibilityElement(children: .combine)
    }

    private var statusLine: String {
        var parts = [match.connection.status.title, match.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let find = match.openFind, find.status == .accepted { parts.insert("Finding each other", at: 0) }
        return parts.joined(separator: " · ")
    }

    private var needsResponse: Bool {
        guard let me = state.userID else { return false }
        return (match.openFind?.status == .pending && match.openFind?.requesterID != me)
            || match.actions.contains { $0.status == .pending && $0.actorID != me }
    }
}
