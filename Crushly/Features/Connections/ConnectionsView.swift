import SwiftUI

/// Connections: one row per active match. Never shows where or when anyone was, only the conversation.
struct ConnectionsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ScreenHeading(
                    title: "Connections",
                    subtitle: "Mutual matches and private conversations.",
                    trailing: state.config.isDemo ? AnyView(DemoBadge()) : nil
                )
                .padding(.top, Theme.Space.s)

                if !state.conversationsLoaded, let error = state.conversationsError {
                    EmptyStateView(symbol: state.isOffline ? "wifi.slash" : "exclamationmark.triangle",
                                   title: state.isOffline ? "You're offline" : "Couldn't load conversations",
                                   message: error,
                                   action: ("Try again", { Task { await state.refreshConversations() } }))
                        .accessibilityIdentifier("connections.error")
                } else if !state.conversationsLoaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, Theme.Space.xxl)
                } else if state.conversations.isEmpty {
                    EmptyStateView(symbol: "heart.text.square", title: "No matches yet",
                                   message: "When you and someone in the same campus space are both interested, you'll match and can chat here.")
                        .accessibilityIdentifier("connections.empty")
                } else {
                    ForEach(state.conversations) { conversation in
                        NavigationLink(value: conversation.id) {
                            ConversationRow(conversation: conversation)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("conversation.\(conversation.other.firstName)")
                    }
                }
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.top, Theme.Space.s)
            .crushScrollPadding()
        }
        .scrollIndicators(.hidden)
        .refreshable { await state.refreshConversations() }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: UUID.self) { id in
            ChatThreadView(matchID: id)
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        PersonRow(person: conversation.other, detail: conversation.previewLine)
            .overlay(alignment: .topTrailing) {
                if conversation.unread {
                    Circle().fill(Theme.Palette.crush).frame(width: 12, height: 12).padding(Theme.Space.m)
                        .accessibilityLabel("Unread")
                }
            }
    }
}

