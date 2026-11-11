import SwiftUI

struct PersonProfileSheet: View {
    @Environment(\.dismiss) private var dismiss

    let person: PulsePerson

    @State private var pulseSent = false
    @State private var heartBeating = false
    @State private var signalExpanded = false
    @State private var showSentText = false

    var body: some View {
        ZStack {
            PulseStyle.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Spacer()

                heartButton

                profileInformation
                    .padding(.top, 30)

                Spacer()

                statusCard
                    .padding(.horizontal, 24)
                    .padding(.bottom, 30)
            }
        }
        .onAppear {
            heartBeating = true
        }
    }

    private var header: some View {
        HStack {
            Button {
                PulseFeedbackManager.shared.lightHaptic()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.black)
                    .frame(width: 48, height: 48)
                    .background(.white.opacity(0.75))
                    .clipShape(Circle())
            }

            Spacer()

            Text("PROFILE")
                .font(.system(size: 11, weight: .bold))
                .tracking(2)
                .foregroundStyle(.black.opacity(0.35))

            Spacer()

            Color.clear
                .frame(width: 48, height: 48)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
    }

    private var heartButton: some View {
        Button {
            sendPulse()
        } label: {
            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .stroke(
                            person.color.opacity(
                                0.28 -
                                Double(index) * 0.06
                            ),
                            lineWidth: 2
                        )
                        .frame(
                            width: CGFloat(
                                210 + index * 46
                            ),
                            height: CGFloat(
                                210 + index * 46
                            )
                        )
                        .scaleEffect(
                            signalExpanded ? 1.22 : 0.72
                        )
                        .opacity(
                            signalExpanded ? 0 : 0.7
                        )
                }

                Circle()
                    .fill(
                        person.color.opacity(
                            pulseSent ? 0.20 : 0.12
                        )
                    )
                    .frame(width: 225, height: 225)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: pulseSent
                                ? [
                                    PulseStyle.pink,
                                    Color.red
                                ]
                                : [
                                    person.color,
                                    person.color.opacity(0.72)
                                ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 168, height: 168)
                    .shadow(
                        color: person.color.opacity(
                            pulseSent ? 0.55 : 0.22
                        ),
                        radius: pulseSent ? 28 : 10
                    )

                VStack(spacing: 9) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(.white)

                    Text(
                        pulseSent
                            ? "PULSE SENT"
                            : "SEND A PULSE"
                    )
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(.white)
                }
            }
            .frame(width: 340, height: 340)
            .scaleEffect(
                heartBeating ? 1.035 : 0.96
            )
            .animation(
                .easeInOut(duration: 0.78)
                    .repeatForever(
                        autoreverses: true
                    ),
                value: heartBeating
            )
            .animation(
                .easeOut(duration: 1.15),
                value: signalExpanded
            )
        }
        .buttonStyle(.plain)
        .disabled(pulseSent)
    }

    private var profileInformation: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text("\(person.name), \(person.age)")
                    .font(.system(size: 34, weight: .bold))

                Text(
                    "\(person.direction) · Within \(person.distance)m"
                )
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.black.opacity(0.45))
            }

            HStack(spacing: 9) {
                ForEach(
                    person.interests,
                    id: \.self
                ) { interest in
                    Text(interest)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.8))
                        .clipShape(Capsule())
                }
            }

            if showSentText {
                Text("Your interest was sent privately.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PulseStyle.pink)
                    .transition(
                        .opacity.combined(
                            with: .move(edge: .top)
                        )
                    )
            }
        }
    }

    private var statusCard: some View {
        HStack(spacing: 13) {
            Circle()
                .fill(
                    pulseSent
                        ? Color.green.opacity(0.16)
                        : Color.black.opacity(0.06)
                )
                .frame(width: 42, height: 42)
                .overlay {
                    Image(
                        systemName: pulseSent
                            ? "checkmark"
                            : "hand.tap.fill"
                    )
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(
                        pulseSent
                            ? Color.green
                            : Color.black.opacity(0.5)
                    )
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(
                    pulseSent
                        ? "Signal delivered"
                        : "Tap the heart"
                )
                .font(.system(size: 14, weight: .bold))

                Text(
                    pulseSent
                        ? "Only \(person.name) can complete the signal."
                        : "Your Pulse will remain private."
                )
                .font(.system(size: 11))
                .foregroundStyle(.black.opacity(0.43))
            }

            Spacer()
        }
        .padding(16)
        .background(.white.opacity(0.72))
        .clipShape(
            RoundedRectangle(cornerRadius: 20)
        )
    }

    private func sendPulse() {
        guard !pulseSent else {
            return
        }

        PulseFeedbackManager.shared.playEffect(
            "heartbeat",
            volume: 1
        )

        PulseFeedbackManager.shared.heartbeatHaptic()

        withAnimation(
            .spring(
                response: 0.45,
                dampingFraction: 0.72
            )
        ) {
            pulseSent = true
        }

        signalExpanded = false

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.04
        ) {
            signalExpanded = true
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.38
        ) {
            PulseFeedbackManager.shared.playEffect(
                "signal",
                volume: 0.8
            )
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.55
        ) {
            withAnimation(.easeOut(duration: 0.4)) {
                showSentText = true
            }
        }
    }
}
