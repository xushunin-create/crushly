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
                    Menu {
                        Button("Not right now") { state.feedback.play(.tap) }
                        Button("Mute signal alerts for 8 hours") { Task { await mute(hours: 8) } }
                        Button("Mute signal alerts for 24 hours") { Task { await mute(hours: 24) } }
                    } label: {
                        Text("Not Right Now").frame(maxWidth: .infinity, minHeight: 54)
                            .font(Theme.Typeface.button)
                            .foregroundStyle(.white)
                            .overlay(Capsule().stroke(.white.opacity(0.6), lineWidth: 1.5))
                    }
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

    private func receiptText(_ receipt: SignalReceipt) -> String {
        let time = receipt.receivedBucket.formatted(.relative(presentation: .named))
        if let space = receipt.spaceName { return "Around \(time) · \(space)" }
        return "Around \(time)"
    }

    private func mute(hours: Double) async {
        var prefs = state.prefs
        prefs.signalsMutedUntil = state.now().addingTimeInterval(hours * 3600)
        await state.updatePrefs(prefs)
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
