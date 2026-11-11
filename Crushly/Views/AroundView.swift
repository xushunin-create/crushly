import SwiftUI

struct AroundView: View {
    @State private var pulseIsLive = true
    @State private var selectedPerson: PulsePerson?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                locationCard

                radar
                    .frame(height: 390)

                statistics
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .sheet(item: $selectedPerson) { person in
            PersonProfileSheet(person: person)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("SURROUNDING YOU")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(.black.opacity(0.4))

                Text("Your radius")
                    .font(.system(size: 30, weight: .bold))
            }

            Spacer()

            Circle()
                .fill(.purple.opacity(0.16))
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.purple)
                }
        }
    }

    private var locationCard: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.green)
                .frame(width: 9, height: 9)
                .shadow(color: .green, radius: 5)

            VStack(alignment: .leading, spacing: 3) {
                Text("USC CAMPUS")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)

                Text("18 people within 500m")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer()

            Button {
                PulseFeedbackManager.shared.lightHaptic()

                withAnimation {
                    pulseIsLive.toggle()
                }
            } label: {
                Text(pulseIsLive ? "LIVE" : "PAUSED")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(
                        pulseIsLive
                            ? PulseStyle.lime
                            : Color.white.opacity(0.5)
                    )
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 72)
        .background(.black.opacity(0.9))
        .clipShape(
            RoundedRectangle(cornerRadius: 24)
        )
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(PulseStyle.pink)
                .frame(height: 5)
                .padding(.horizontal, 8)
        }
    }

    private var radar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let size = min(width, height)

            ZStack {
                radarBackground(size: size)

                centerPulse(size: size)

                if pulseIsLive {
                    ForEach(demoPeople) { person in
                        radarPoint(
                            person,
                            width: width,
                            height: height
                        )
                    }
                }
            }
            .frame(
                width: width,
                height: height
            )
        }
    }

    private func radarBackground(
        size: CGFloat
    ) -> some View {
        ZStack {
            Circle()
                .stroke(
                    Color.pink.opacity(0.18),
                    lineWidth: 1
                )
                .frame(
                    width: size * 0.92,
                    height: size * 0.92
                )

            Circle()
                .stroke(
                    Color.pink.opacity(0.22),
                    style: StrokeStyle(
                        lineWidth: 1,
                        dash: [4, 4]
                    )
                )
                .frame(
                    width: size * 0.67,
                    height: size * 0.67
                )

            Circle()
                .stroke(
                    Color.pink.opacity(0.26),
                    lineWidth: 1
                )
                .frame(
                    width: size * 0.42,
                    height: size * 0.42
                )

            Rectangle()
                .fill(Color.pink.opacity(0.11))
                .frame(
                    width: size * 0.92,
                    height: 1
                )

            Rectangle()
                .fill(Color.pink.opacity(0.11))
                .frame(
                    width: 1,
                    height: size * 0.92
                )
        }
    }

    private func centerPulse(
        size: CGFloat
    ) -> some View {
        ZStack {
            Circle()
                .fill(
                    pulseIsLive
                        ? PulseStyle.pink
                        : Color.gray.opacity(0.45)
                )
                .frame(
                    width: size * 0.41,
                    height: size * 0.41
                )
                .shadow(
                    color: .black.opacity(0.25),
                    radius: 0,
                    x: 8,
                    y: 9
                )

            VStack(spacing: 7) {
                Image(
                    systemName: pulseIsLive
                        ? "heart.fill"
                        : "heart.slash"
                )
                .font(.system(size: 31))
                .foregroundStyle(.white)

                Text(
                    pulseIsLive
                        ? "PULSE IS LIVE"
                        : "PULSE PAUSED"
                )
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)

                Text("500M RADIUS")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    private func radarPoint(
        _ person: PulsePerson,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        Button {
            PulseFeedbackManager.shared.lightHaptic()
            selectedPerson = person
        } label: {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: 29, height: 29)
                    .shadow(
                        color: .black.opacity(0.14),
                        radius: 4
                    )

                Circle()
                    .fill(person.color)
                    .frame(width: 17, height: 17)
            }
        }
        .buttonStyle(.plain)
        .position(
            x: person.radarX * width,
            y: person.radarY * height
        )
    }

    private var statistics: some View {
        HStack(spacing: 0) {
            statistic(value: "18", title: "AROUND")

            Divider()
                .frame(height: 42)

            statistic(value: "3", title: "LIKES")

            Divider()
                .frame(height: 42)

            statistic(value: "1", title: "MUTUAL")
        }
        .padding(.vertical, 17)
        .background(.white.opacity(0.62))
        .clipShape(
            RoundedRectangle(cornerRadius: 20)
        )
    }

    private func statistic(
        value: String,
        title: String
    ) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .bold))

            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(1)
                .foregroundStyle(.black.opacity(0.38))
        }
        .frame(maxWidth: .infinity)
    }
}
