import SwiftUI

struct ContentView: View {
    @State private var selectedTab: PulseTab = .around

    var body: some View {
        ZStack(alignment: .bottom) {
            PulseStyle.background
                .ignoresSafeArea()

            Group {
                switch selectedTab {
                case .around:
                    AroundView()

                case .likes:
                    LikesView()

                case .me:
                    ProfileSafetyView()
                }
            }
            .padding(.bottom, 82)

            PulseTabBar(
                selectedTab: $selectedTab
            )
        }
        .preferredColorScheme(.light)
    }
}

#Preview {
    ContentView()
}
