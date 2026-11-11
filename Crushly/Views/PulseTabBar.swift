import SwiftUI

enum PulseTab {
    case around
    case likes
    case me
}

struct PulseTabBar: View {
    @Binding var selectedTab: PulseTab

    var body: some View {
        HStack {
            tabButton(
                tab: .around,
                icon: "location.circle.fill",
                title: "Around"
            )

            Spacer()

            tabButton(
                tab: .likes,
                icon: "heart.fill",
                title: "Likes"
            )

            Spacer()

            tabButton(
                tab: .me,
                icon: "person.crop.circle.fill",
                title: "Me"
            )
        }
        .padding(.horizontal, 42)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(
            PulseStyle.tabBarBackground
                .shadow(
                    color: .black.opacity(0.08),
                    radius: 12,
                    y: -4
                )
        )
    }

    private func tabButton(
        tab: PulseTab,
        icon: String,
        title: String
    ) -> some View {
        Button {
            PulseFeedbackManager.shared.lightHaptic()

            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    if selectedTab == tab {
                        Circle()
                            .fill(PulseStyle.pink)
                            .frame(width: 38, height: 38)
                    }

                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundStyle(
                            selectedTab == tab
                                ? Color.white
                                : Color.black.opacity(0.32)
                        )
                }
                .frame(height: 38)

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        selectedTab == tab
                            ? Color.black
                            : Color.black.opacity(0.32)
                    )
            }
        }
        .buttonStyle(.plain)
    }
}
