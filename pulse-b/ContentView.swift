import SwiftUI
import AVFoundation
import UIKit

// MARK: - Models

enum PulseTab {
    case around
    case likes
    case me
}

struct PulsePerson: Identifiable {
    let id = UUID()
    let name: String
    let age: Int
    let direction: String
    let distance: Int
    let symbol: String
    let color: Color
    let interests: [String]
    let radarX: CGFloat
    let radarY: CGFloat
}

// MARK: - Demo Data

let demoPeople: [PulsePerson] = [
    PulsePerson(
        name: "Mina",
        age: 22,
        direction: "Northwest",
        distance: 120,
        symbol: "music.note",
        color: .pink,
        interests: ["Music", "Film", "Late-night food"],
        radarX: 0.24,
        radarY: 0.28
    ),

    PulsePerson(
        name: "Alex",
        age: 21,
        direction: "East",
        distance: 230,
        symbol: "gamecontroller.fill",
        color: .purple,
        interests: ["Games", "Design", "Coffee"],
        radarX: 0.78,
        radarY: 0.48
    ),

    PulsePerson(
        name: "Jamie",
        age: 23,
        direction: "Southwest",
        distance: 380,
        symbol: "camera.fill",
        color: .blue,
        interests: ["Photography", "Concerts", "Hiking"],
        radarX: 0.22,
        radarY: 0.76
    ),

    PulsePerson(
        name: "Noah",
        age: 22,
        direction: "Northeast",
        distance: 460,
        symbol: "sparkles",
        color: .orange,
        interests: ["Startups", "Movies", "Tennis"],
        radarX: 0.73,
        radarY: 0.20
    )
]

// MARK: - Audio and Haptic Feedback

final class PulseV2Feedback {
    static let shared = PulseV2Feedback()

    private var audioPlayers: [String: AVAudioPlayer] = [:]

    private init() {
        configureAudio()
    }

    private func configureAudio() {
        do {
            let session = AVAudioSession.sharedInstance()

            try session.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]
            )

            try session.setActive(true)
        } catch {
            print(
                "Audio configuration error: \(error.localizedDescription)"
            )
        }
    }

    func playEffect(
        _ name: String,
        volume: Float = 1.0
    ) {
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: "wav"
        ) else {
            print("Could not find \(name).wav")
            return
        }

        do {
            let player = try AVAudioPlayer(
                contentsOf: url
            )

            player.volume = volume
            player.prepareToPlay()

            audioPlayers[name] = player
            player.play()
        } catch {
            print(
                "Audio error: \(error.localizedDescription)"
            )
        }
    }

    func lightHaptic() {
        let generator = UIImpactFeedbackGenerator(
            style: .light
        )

        generator.prepare()
        generator.impactOccurred()
    }

    func heartbeatHaptic() {
        let generator = UIImpactFeedbackGenerator(
            style: .heavy
        )

        generator.prepare()
        generator.impactOccurred(intensity: 1)

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.22
        ) {
            generator.prepare()
            generator.impactOccurred(intensity: 0.72)
        }
    }

    func successHaptic() {
        let generator =
            UINotificationFeedbackGenerator()

        generator.prepare()
        generator.notificationOccurred(.success)
    }
}

// MARK: - Root View

struct ContentView: View {
    @State private var selectedTab: PulseTab = .around

    var body: some View {
        ZStack(alignment: .bottom) {
            appBackground
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

    private var appBackground: Color {
        Color(
            red: 0.965,
            green: 0.95,
            blue: 0.92
        )
    }
}

// MARK: - Tab Bar

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
            Color(
                red: 0.985,
                green: 0.975,
                blue: 0.95
            )
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
            PulseV2Feedback.shared.lightHaptic()

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

// MARK: - Shared Style

enum PulseStyle {
    static let background = Color(
        red: 0.965,
        green: 0.95,
        blue: 0.92
    )

    static let pink = Color(
        red: 0.95,
        green: 0.24,
        blue: 0.38
    )

    static let lime = Color(
        red: 0.78,
        green: 1.0,
        blue: 0.25
    )
}

// MARK: - Around View

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
                PulseV2Feedback.shared.lightHaptic()

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
            PulseV2Feedback.shared.lightHaptic()
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

// MARK: - Person Profile Sheet

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
                PulseV2Feedback.shared.lightHaptic()
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

        PulseV2Feedback.shared.playEffect(
            "heartbeat",
            volume: 1
        )

        PulseV2Feedback.shared.heartbeatHaptic()

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
            PulseV2Feedback.shared.playEffect(
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

// MARK: - Likes View

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
                PulseV2Feedback.shared.playEffect(
                    "signal",
                    volume: 0.7
                )

                PulseV2Feedback.shared.successHaptic()

                withAnimation(.spring(response: 0.4)) {
                    likedBackIDs.insert(person.id)
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

// MARK: - Profile and Safety

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
                    PulseV2Feedback.shared.lightHaptic()
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
                    PulseV2Feedback.shared.lightHaptic()
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

// MARK: - Preview

#Preview {
    ContentView()
}
