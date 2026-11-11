import AVFoundation
import UIKit

/// The only place that plays sounds or haptics. Screens trigger named moments; this decides how they feel.
/// Sounds use the `.ambient` category, so they respect the silent switch and mix with the user's music.
final class FeedbackService {
    enum Moment {
        /// Selection, tab change, toggle.
        case tap
        /// Pulse Mode turned on.
        case pulseOn
        /// A Heart Signal left successfully: heartbeat + crisp signal + light haptics.
        case signalSent
        /// Mutual match reveal: bell sequence + two heartbeat haptic pulses.
        case heartSync
        /// Something accepted / saved.
        case success
        /// A rule blocked the action.
        case warning
    }

    static let shared = FeedbackService()

    /// User preference (Me › Notifications & sound).
    var soundsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "crushly.sounds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "crushly.sounds") }
    }

    private var players: [String: AVAudioPlayer] = [:]
    private var configured = false

    private init() {}

    func play(_ moment: Moment) {
        switch moment {
        case .tap:
            impact(.light)
        case .pulseOn:
            impact(.medium)
            sound("signal", volume: 0.5)
        case .signalSent:
            sound("heartbeat", volume: 0.9)
            impact(.light)
            after(0.38) {
                self.sound("signal", volume: 0.75)
                self.impact(.light, intensity: 0.7)
            }
        case .heartSync:
            sound("bell", volume: 0.85)
            heartbeatPair(delay: 0.1)
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    // MARK: Private

    private func heartbeatPair(delay: TimeInterval) {
        after(delay) { self.impact(.heavy) }
        after(delay + 0.22) { self.impact(.heavy, intensity: 0.7) }
    }

    private func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat = 1) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred(intensity: intensity)
    }

    private func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func sound(_ name: String, volume: Float) {
        guard soundsEnabled else { return }
        configureIfNeeded()
        if players[name] == nil {
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav"),
                  let player = try? AVAudioPlayer(contentsOf: url) else { return }
            player.prepareToPlay()
            players[name] = player
        }
        guard let player = players[name] else { return }
        player.volume = volume
        player.currentTime = 0
        player.play()
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
    }
}
