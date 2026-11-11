import SwiftUI

struct ProfileSafetyView: View {
    @State private var pulseVisible = true
    @State private var hidePreciseLocation = true
    @State private var onlyVerifiedUsers = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MY PULSE")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(.black.opacity(0.4))

                    Text("Profile & Safety")
                        .font(.system(size: 30, weight: .bold))
                }

                profileCard

                Text("SAFETY CONTROLS")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(.black.opacity(0.4))

                VStack(spacing: 0) {
                    safetyToggle(
                        icon: "eye.fill",
                        title: "Visible in Around",
                        subtitle: "Allow nearby users to see you",
                        value: $pulseVisible
                    )

                    Divider()
                        .padding(.leading, 54)

                    safetyToggle(
                        icon: "location.slash.fill",
                        title: "Hide precise location",
                        subtitle: "Only show a general distance range",
                        value: $hidePreciseLocation
                    )

                    Divider()
                        .padding(.leading, 54)

                    safetyToggle(
                        icon: "checkmark.shield.fill",
                        title: "Verified users only",
                        subtitle: "Only appear to verified students",
                        value: $onlyVerifiedUsers
                    )
                }
                .background(.white.opacity(0.7))
                .clipShape(
                    RoundedRectangle(cornerRadius: 22)
                )

                Button {
                    PulseFeedbackManager.shared.lightHaptic()
                    pulseVisible = false
                } label: {
                    HStack {
                        Image(systemName: "shield.fill")

                        Text("PAUSE AND HIDE ME")
                            .font(.system(size: 14, weight: .bold))

                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(height: 58)
                    .background(.black.opacity(0.9))
                    .clipShape(
                        RoundedRectangle(cornerRadius: 20)
                    )
                }

                Button {
                    PulseFeedbackManager.shared.lightHaptic()
                } label: {
                    HStack {
                        Image(
                            systemName:
                                "exclamationmark.triangle.fill"
                        )

                        Text("REPORT OR BLOCK SOMEONE")
                            .font(.system(size: 13, weight: .semibold))

                        Spacer()

                        Image(systemName: "chevron.right")
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, 18)
                    .frame(height: 56)
                    .background(.red.opacity(0.08))
                    .clipShape(
                        RoundedRectangle(cornerRadius: 18)
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 30)
        }
    }

    private var profileCard: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(.purple.opacity(0.17))
                .frame(width: 76, height: 76)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.purple)
                }

            VStack(alignment: .leading, spacing: 6) {
                Text("Jessie, 22")
                    .font(.system(size: 22, weight: .bold))

                Text("USC · Iovine and Young Academy")
                    .font(.system(size: 12))
                    .foregroundStyle(.black.opacity(0.48))

                Text("Music · Design · Games")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.pink)
            }

            Spacer()

            Image(systemName: "pencil")
                .foregroundStyle(.black.opacity(0.45))
        }
        .padding(18)
        .background(.white.opacity(0.7))
        .clipShape(
            RoundedRectangle(cornerRadius: 24)
        )
    }

    private func safetyToggle(
        icon: String,
        title: String,
        subtitle: String,
        value: Binding<Bool>
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(.black.opacity(0.7))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.black.opacity(0.42))
            }

            Spacer()

            Toggle("", isOn: value)
                .labelsHidden()
                .tint(PulseStyle.lime)
        }
        .padding(16)
    }
}
