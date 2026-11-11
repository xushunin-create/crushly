import SwiftUI

struct LikesView: View {
    @State private var likedBackIDs: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LIKES YOU")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(.black.opacity(0.4))

                    Text("People who noticed you")
                        .font(.system(size: 29, weight: .bold))
                }

                likesSummary

                ForEach(demoPeople.prefix(3)) { person in
                    likeCard(person)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 30)
        }
    }

    private var likesSummary: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("3 NEW SIGNALS")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)

                Text("One may already be mutual.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer()

            Image(systemName: "heart.fill")
                .font(.system(size: 30))
                .foregroundStyle(.pink)
        }
        .padding(18)
        .background(.black.opacity(0.9))
        .clipShape(
            RoundedRectangle(cornerRadius: 22)
        )
    }

    private func likeCard(
        _ person: PulsePerson
    ) -> some View {
        HStack(spacing: 16) {
            Circle()
                .fill(person.color)
                .frame(width: 66, height: 66)
                .overlay {
                    Image(systemName: person.symbol)
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 6) {
                Text("\(person.name), \(person.age)")
                    .font(.system(size: 18, weight: .bold))

                Text(
                    "\(person.direction) · Within \(person.distance)m"
                )
                .font(.system(size: 12))
                .foregroundStyle(.black.opacity(0.45))

                Text(
                    likedBackIDs.contains(person.id)
                        ? "Mutual Pulse"
                        : "Sent you a Pulse"
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    likedBackIDs.contains(person.id)
                        ? Color.green
                        : Color.pink
                )
            }

            Spacer()

            Button {
                PulseFeedbackManager.shared.playEffect(
                    "signal",
                    volume: 0.7
                )

                PulseFeedbackManager.shared.successHaptic()

                withAnimation(.spring(response: 0.4)) {
                    _ = likedBackIDs.insert(person.id)
                }
            } label: {
                Image(
                    systemName:
                        likedBackIDs.contains(person.id)
                        ? "checkmark"
                        : "heart.fill"
                )
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(
                    likedBackIDs.contains(person.id)
                        ? Color.green
                        : Color.pink
                )
                .clipShape(Circle())
            }
            .disabled(
                likedBackIDs.contains(person.id)
            )
        }
        .padding(16)
        .background(.white.opacity(0.66))
        .clipShape(
            RoundedRectangle(cornerRadius: 22)
        )
    }
}
