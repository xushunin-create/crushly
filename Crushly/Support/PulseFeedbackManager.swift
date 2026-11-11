import AVFoundation
import UIKit

final class PulseFeedbackManager {
    static let shared = PulseFeedbackManager()

    private var effectPlayers: [String: AVAudioPlayer] = [:]

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
                "Audio session error: \(error.localizedDescription)"
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

            effectPlayers[name] = player
            player.play()
        } catch {
            print(
                "Audio playback error: \(error.localizedDescription)"
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
        generator.impactOccurred(intensity: 1.0)

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
