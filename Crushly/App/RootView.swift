import SwiftUI

/// Routes on `AppState.phase` and hosts the three main tabs.
struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            RetroBackground()

            switch state.phase {
            case .launching:
                LaunchView()
            case .signedOut:
                SignInView()
            case .needsTerms:
                TermsView()
            case .needsProfile:
                NavigationStack { ProfileEditorView(mode: .onboarding) }
            case .ready:
                MainTabs()
            }
        }
        .overlay(alignment: .top) {
            if let message = state.errorMessage {
                ErrorBanner(message: message) { state.errorMessage = nil }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(5))
                        if state.errorMessage == message { state.errorMessage = nil }
                    }
            }
        }
        .overlay(alignment: .bottom) {
            if state.isOffline {
                Label("Offline — retrying", systemImage: "wifi.slash")
                    .font(Theme.Typeface.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, Theme.Space.s)
                    .background(Theme.Palette.ink, in: Capsule())
                    .padding(.bottom, 96)
                    .transition(.opacity)
                    .accessibilityLabel("You're offline. Crushly will retry automatically.")
            }
        }
        .animation(Theme.Motion.soft, value: state.isOffline)
        .animation(Theme.Motion.soft, value: state.errorMessage)
        .animation(Theme.Motion.soft, value: state.phase)
        .preferredColorScheme(.light)
        .tint(Theme.Palette.crush)
    }
}

private struct LaunchView: View {
    var body: some View {
        VStack(spacing: Theme.Space.l) {
            ZStack {
                SparkRays()
                HeartMark(size: 72)
            }
            Text("Crushly")
                .font(Theme.Typeface.display)
                .foregroundStyle(Theme.Palette.oxblood)
            Text("real-life crushes")
                .font(Theme.Typeface.title2)
                .foregroundStyle(Theme.Palette.crush)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Crushly is loading")
    }
}

struct MainTabs: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        ZStack(alignment: .bottom) {
            Group {
                switch state.selectedTab {
                case .around: NavigationStack { AroundView() }
                case .signals: NavigationStack(path: $state.signalsPath) { SignalsView() }
                case .me: NavigationStack { MeView() }
                }
            }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 64) }

            CrushTabBar(selection: $state.selectedTab, signalsBadge: state.receipts.count + pendingIncoming)
        }
        .fullScreenCover(item: $state.revealMatch) { match in
            HeartSyncRevealView(match: match)
        }
    }

    private var pendingIncoming: Int {
        guard let me = state.userID else { return 0 }
        return state.activeMatches.filter { match in
            (match.openFind?.status == .pending && match.openFind?.requesterID != me)
                || match.actions.contains { $0.status == .pending && $0.actorID != me }
        }.count
    }
}

struct CrushTabBar: View {
    @Binding var selection: AppState.Tab
    var signalsBadge: Int
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 0) {
            item(.around, "Around", "dot.radiowaves.left.and.right")
            item(.signals, "Signals", "heart.text.square.fill", badge: signalsBadge)
            item(.me, "Me", "person.crop.circle.fill")
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.s)
        // Like the system tab bar: labels stop growing at XL; long-press shows the Large Content Viewer.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26)
                .fill(Theme.Palette.surface.opacity(0.97))
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.Palette.oxblood.opacity(0.08)).frame(height: 1)
                }
                .shadow(color: Theme.Palette.oxblood.opacity(0.12), radius: 16, y: -4)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func item(_ tab: AppState.Tab, _ title: String, _ icon: String, badge: Int = 0) -> some View {
        let selected = selection == tab
        return Button {
            guard selection != tab else { return }
            state.feedback.play(.tap)
            withAnimation(Theme.Motion.snappy) { selection = tab }
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 48, height: 30)
                        .background(selected ? Theme.Palette.oxblood : .clear, in: Capsule())
                        .foregroundStyle(selected ? .white : Theme.Palette.inkSoft)
                    if badge > 0 {
                        Text("\(min(badge, 9))")
                            .font(.system(.caption2, design: .rounded).weight(.heavy))
                            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                            .foregroundStyle(.white)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Theme.Palette.ink, in: Circle())
                            .offset(x: 6, y: -6)
                    }
                }
                Text(title)
                    .font(Theme.Typeface.caption.weight(.bold))
                    .foregroundStyle(selected ? Theme.Palette.ink : Theme.Palette.inkSoft)
            }
            .frame(maxWidth: .infinity, minHeight: Theme.minTap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(title), \(badge) new" : title)
        .accessibilityIdentifier("tab.\(title.lowercased())")
        .accessibilityShowsLargeContentViewer {
            Label(title, systemImage: icon)
        }
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
