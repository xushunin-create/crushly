import SwiftUI

/// A single mutual connection: lifecycle, Connect Later actions, Instagram swap, and Find Each Other.
struct MatchDetailView: View {
    let matchID: UUID

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var showFind = false
    @State private var showSafety = false
    @State private var instagram: String?
    @State private var confirmLetGo = false

    private var match: Match? { state.matches.first { $0.id == matchID } }

    var body: some View {
        Group {
            if let match { content(match) } else {
                EmptyStateView(symbol: "heart.slash", title: "No longer available", message: "This connection was removed.")
            }
        }
        .background(Theme.Palette.paper)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ match: Match) -> some View {
        let me = state.userID
        let active = [.pendingConfirmation, .metTonight, .findLater].contains(match.connection.status)
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header(match)

                if let find = match.openFind, find.status == .pending || find.status == .accepted {
                    FindStatusCard(match: match, request: find)
                }

                let incoming = match.actions.filter { $0.status == .pending && $0.actorID != me }
                ForEach(incoming) { action in incomingCard(action) }

                if active {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        Eyebrow(text: "Status")
                        HStack(spacing: Theme.Space.s) {
                            statusButton(match, .metTonight, "We met tonight")
                            statusButton(match, .findLater, "Find later")
                        }
                    }

                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        Eyebrow(text: "Make a move")
                        if isSyncAndLive(match) {
                            Button { showFind = true } label: { Label("Find Each Other Now", systemImage: "figure.walk") }
                                .buttonStyle(.crush)
                        }
                        actionButton(match, .coffee, detail: nil)
                        actionButton(match, .studyBreak, detail: nil)
                        Menu {
                            ForEach(ConversationStarters.all, id: \.self) { starter in
                                Button(starter) { Task { await state.sendAction(match, kind: .starter, detail: starter) } }
                            }
                        } label: { actionLabel(.starter, status: latest(match, .starter)) }
                            .disabled(latest(match, .starter)?.status == .pending)
                        actionButton(match, .instagramExchange, detail: nil)
                        if let instagram {
                            Label("\(match.other.firstName)'s Instagram: \(instagram)", systemImage: "camera.circle.fill")
                                .font(Theme.Typeface.callout.weight(.semibold))
                                .textSelection(.enabled)
                                .crushCard(fill: Theme.Palette.mintSoft)
                        }
                    }

                    history(match)

                    Button(role: .destructive) { confirmLetGo = true } label: { Text("Let this connection go") }
                        .buttonStyle(.crush(.destructive))
                } else {
                    Text(match.connection.status == .expired
                         ? "This connection expired. Your past mutual interest doesn't make either of you visible again."
                         : "This connection was removed.")
                        .font(Theme.Typeface.callout).foregroundStyle(Theme.Palette.inkSoft)
                    if match.connection.status == .expired {
                        AsyncButton { await state.setConnection(match, status: .removed) } label: { Text("Remove") }
                            .buttonStyle(.crush(.quiet))
                    }
                }
            }
            .padding(Theme.Space.gutter)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSafety = true } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Safety options")
            }
        }
        .sheet(isPresented: $showFind) { FindRequestSheet(match: match) {}.presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showSafety) { SafetyActionsSheet(person: match.other) { dismiss() } }
        .confirmationDialog("Let \(match.other.firstName) go?", isPresented: $confirmLetGo, titleVisibility: .visible) {
            Button("Let go", role: .destructive) {
                Task {
                    await state.setConnection(match, status: .removed)
                    dismiss()
                }
            }
        } message: { Text("The connection disappears for both of you. They won't be told why.") }
        .task(id: match.actions.map(\.status)) { instagram = await state.instagram(for: match) }
    }

    private func header(_ match: Match) -> some View {
        HStack(spacing: Theme.Space.l) {
            Avatar(path: match.other.photoPaths.first, name: match.other.firstName, size: 84)
            VStack(alignment: .leading, spacing: 4) {
                Text(match.kind.title.uppercased()).font(Theme.Typeface.eyebrow).tracking(1.5)
                    .foregroundStyle(match.kind == .heartSync ? Theme.Palette.crush : Theme.Palette.plum)
                Text(match.other.firstName).font(Theme.Typeface.display)
                Text([match.spaceName, match.createdAt.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.Typeface.caption).foregroundStyle(Theme.Palette.inkSoft)
                if let deadline = match.connection.deadline {
                    Text(match.connection.status == .pendingConfirmation
                         ? "Confirm \(deadline.formatted(.relative(presentation: .named))) or it expires"
                         : "Stays active until \(deadline.formatted(date: .abbreviated, time: .omitted)) — any action keeps it going")
                        .font(Theme.Typeface.caption.weight(.semibold)).foregroundStyle(Theme.Palette.amber)
                }
            }
        }
    }

    private func isSyncAndLive(_ match: Match) -> Bool {
        state.pulseState == .live && !(match.openFind.map { $0.status == .pending || $0.status == .accepted } ?? false)
    }

    private func latest(_ match: Match, _ kind: ConnectionActionKind) -> ConnectionAction? {
        match.actions.filter { $0.kind == kind && $0.actorID == state.userID }.max { $0.createdAt < $1.createdAt }
    }

    private func statusButton(_ match: Match, _ status: ConnectionStatus, _ title: String) -> some View {
        SelectableChip(title: title, selected: match.connection.status == status, tint: Theme.Palette.ink) {
            Task { await state.setConnection(match, status: status) }
        }
    }

    private func actionButton(_ match: Match, _ kind: ConnectionActionKind, detail: String?) -> some View {
        let last = latest(match, kind)
        return Button { Task { await state.sendAction(match, kind: kind, detail: detail) } } label: { actionLabel(kind, status: last) }
            .buttonStyle(.plain)
            .disabled(last?.status == .pending || (kind == .instagramExchange && last?.status == .accepted))
    }

    private func actionLabel(_ kind: ConnectionActionKind, status: ConnectionAction?) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: kind.symbol).foregroundStyle(Theme.Palette.crush).frame(width: 28)
            Text(kind.title).font(Theme.Typeface.callout.weight(.semibold)).foregroundStyle(Theme.Palette.ink)
            Spacer()
            if let status {
                Text(statusText(status.status)).font(Theme.Typeface.caption.weight(.bold)).foregroundStyle(Theme.Palette.inkSoft)
            }
        }
        .frame(minHeight: Theme.minTap)
        .crushCard(padding: Theme.Space.m)
    }

    private func statusText(_ status: RequestStatus) -> String {
        switch status {
        case .pending: "Waiting"
        case .accepted: "Accepted"
        case .declined: "Declined"
        case .cancelled: "Cancelled"
        case .timedOut: "Timed out"
        case .completed: "Done"
        }
    }

    private func incomingCard(_ action: ConnectionAction) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Label(incomingTitle(action), systemImage: action.kind.symbol).font(Theme.Typeface.headline)
            if let detail = action.detail { Text("“\(detail)”").font(Theme.Typeface.body) }
            if action.kind == .instagramExchange {
                Text("Accepting shares your handle with them and theirs with you.").font(Theme.Typeface.footnote).foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: Theme.Space.s) {
                AsyncButton { await state.respond(to: action, accept: true) } label: { Text("Accept") }.buttonStyle(.crush)
                AsyncButton { await state.respond(to: action, accept: false) } label: { Text("Decline") }
                    .buttonStyle(.crush(.onInk))
            }
        }
        .inkCard()
    }

    private func incomingTitle(_ action: ConnectionAction) -> String {
        switch action.kind {
        case .coffee: "They suggested coffee"
        case .studyBreak: "They suggested a study break"
        case .starter: "They sent a conversation starter"
        case .instagramExchange: "They want to swap Instagram"
        }
    }

    @ViewBuilder private func history(_ match: Match) -> some View {
        let done = match.actions.filter { $0.status != .pending }.sorted { $0.createdAt > $1.createdAt }
        if !done.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Eyebrow(text: "History")
                ForEach(done) { action in
                    Text("\(action.actorID == state.userID ? "You" : match.other.firstName): \(action.kind.title.lowercased()) · \(statusText(action.status).lowercased())")
                        .font(Theme.Typeface.footnote).foregroundStyle(Theme.Palette.inkSoft)
                }
            }
        }
    }
}

/// Consent-based meeting: one person proposes a public meeting point; both must accept. No tracking.
struct FindRequestSheet: View {
    let match: Match
    var onSent: () -> Void

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var point = MeetingPoints.presets[0]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    Text("Suggest a public spot. \(match.other.firstName) has \(state.rules.findRequestTimeoutMinutes) minutes to accept. No live location is shared — ever.")
                        .font(Theme.Typeface.callout).foregroundStyle(Theme.Palette.inkSoft)
                    ForEach(MeetingPoints.presets, id: \.self) { preset in
                        SelectableChip(title: preset, selected: point == preset, tint: Theme.Palette.ink) { point = preset }
                    }
                    Label("Meet somewhere public and let a friend know where you'll be.", systemImage: "person.2.fill")
                        .font(Theme.Typeface.footnote).foregroundStyle(Theme.Palette.inkSoft)
                    AsyncButton {
                        await state.requestFind(match, meetingPoint: point)
                        dismiss()
                        onSent()
                    } label: { Text("Ask to meet at \(point)") }
                        .buttonStyle(.crush)
                }
                .padding(Theme.Space.gutter)
            }
            .background(Theme.Palette.paper)
            .navigationTitle("Find Each Other")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct FindStatusCard: View {
    let match: Match
    let request: FindRequest
    @Environment(AppState.self) private var state

    var body: some View {
        let mine = request.requesterID == state.userID
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(request.status == .accepted ? "FIND MODE ON" : "MEETING REQUEST")
                .font(Theme.Typeface.eyebrow).tracking(1.6).foregroundStyle(Theme.Palette.live)
            Text(title(mine: mine)).font(Theme.Typeface.title2)
            Label(request.meetingPoint, systemImage: "mappin.and.ellipse").font(Theme.Typeface.headline)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let deadline = request.status == .accepted ? (request.activeUntil ?? request.respondBy) : request.respondBy
                Text("\(request.status == .accepted ? "Ends" : "Expires") in \(format(deadline.timeIntervalSince(context.date.addingTimeInterval(state.clockSkew))))")
                    .font(Theme.Typeface.subheadline).monospacedDigit().foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: Theme.Space.s) {
                if request.status == .pending && !mine {
                    AsyncButton { await state.respondFind(request, accept: true) } label: { Text("Accept") }.buttonStyle(.crush)
                    AsyncButton { await state.respondFind(request, accept: false) } label: { Text("Decline") }
                        .buttonStyle(.crush(.onInk))
                } else if request.status == .accepted {
                    AsyncButton { await state.completeFind(request) } label: { Text("We found each other") }.buttonStyle(.crush)
                    AsyncButton { await state.cancelFind(request) } label: { Text("Cancel") }
                        .buttonStyle(.crush(.onInk))
                } else {
                    AsyncButton { await state.cancelFind(request) } label: { Text("Cancel request") }
                        .buttonStyle(.crush(.onInk))
                }
            }
        }
        .inkCard(padding: Theme.Space.xl)
    }

    private func title(mine: Bool) -> String {
        switch request.status {
        case .accepted: "Head to the meeting point"
        default: mine ? "Waiting for \(match.other.firstName)…" : "\(match.other.firstName) wants to meet now"
        }
    }
}
