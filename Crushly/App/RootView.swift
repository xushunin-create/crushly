import SwiftUI

/// Routes on `AppState.phase` and hosts the three main tabs.
struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(\.scenePhase) private var scenePhase

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
        #if DEBUG
        .overlay(alignment: .top) {
            if FieldValidationRecorder.shared.isOn, state.phase == .ready { FieldValidationOverlay() }
        }
        #endif
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
        .tint(Theme.Palette.crushText)
        // Background music plays only once the user is signed in and inside the app.
        .onChange(of: state.phase, initial: true) { _, phase in
            if phase == .ready {
                FeedbackService.shared.startMusic()
            } else {
                FeedbackService.shared.stopMusic()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            FeedbackService.shared.sceneDidChange(active: phase == .active)
        }
    }
}

private struct LaunchView: View {
    var body: some View {
        VStack(spacing: Theme.Space.l) {
            CrushlyBrandIcon(size: 88)
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
        Group {
            switch state.selectedTab {
            case .spaces: NavigationStack { SpacesView() }
            case .connections: NavigationStack(path: $state.connectionsPath) { ConnectionsView() }
            case .me: NavigationStack { MeView() }
            }
        }
        // Let SwiftUI reserve the exact tab-bar + Home-indicator height. The old
        // overlay used a guessed 64pt spacer and could cover the last row/button.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsTabBar {
                CrushTabBar(selection: $state.selectedTab, connectionsBadge: state.unreadCount)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .fullScreenCover(item: $state.revealMatch) { match in
            HeartSyncRevealView(match: match)
        }
        .sheet(item: $state.consentPrompt) { prompt in
            ConsentSheet(prompt: prompt)
        }
    }

    /// Like Messages, the tab bar steps aside inside a conversation so the composer is never covered.
    private var showsTabBar: Bool { !(state.selectedTab == .connections && !state.connectionsPath.isEmpty) }
}

struct CrushTabBar: View {
    @Binding var selection: AppState.Tab
    var connectionsBadge: Int
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 0) {
            item(.spaces, "Spaces", "building.columns.fill")
            item(.connections, "Connections", "heart.text.square.fill", badge: connectionsBadge)
            item(.me, "Me", "person.crop.circle.fill")
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, 6)
        // Like the system tab bar: labels stop growing at XL; long-press shows the Large Content Viewer.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28)
                .fill(Theme.Palette.surface.opacity(0.97))
                .overlay(alignment: .top) {
                    Capsule()
                        .fill(Theme.Palette.crush.opacity(0.45))
                        .frame(width: 42, height: 3)
                        .padding(.top, 5)
                }
                .shadow(color: Theme.Palette.oxblood.opacity(0.13), radius: 18, y: -5)
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
                        .frame(width: 54, height: 30)
                        .background(selected ? Theme.Palette.periwinkle : Theme.Palette.periwinkle.opacity(0.06), in: Capsule())
                        .foregroundStyle(selected ? .white : Theme.Palette.inkSoft.opacity(0.88))
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(selected ? Theme.Palette.oxblood : Theme.Palette.inkSoft)
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
