import AVFoundation
import UIKit

/// The only place that plays sounds or haptics. Screens trigger named moments; this decides how they feel.
/// Sounds use the `.ambient` category, so they respect the silent switch and mix with the user's music.
final class FeedbackService {
    enum Moment {
        /// Selection, tab change, toggle.
        case tap
        /// Opened to matching in a campus space.
        case openToMatching
        /// Interest sent: heartbeat + crisp signal + light haptics.
        case interestSent
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

    /// User preference for the looping background music (Me › Alerts). Separate from `soundsEnabled`.
    var musicEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "crushly.music") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "crushly.music")
            updateMusic()
        }
    }

    private static let musicVolume: Float = 0.4

    private var players: [String: AVAudioPlayer] = [:]
    private var configured = false
    private var music: AVAudioPlayer?
    /// True while the user is signed in and inside the app (`AppState.phase == .ready`).
    private var musicWanted = false
    private var sceneActive = true

    private init() {}

    func play(_ moment: Moment) {
        switch moment {
        case .tap:
            impact(.light)
        case .openToMatching:
            impact(.medium)
            sound("signal", volume: 0.5)
        case .interestSent:
            sound("heartbeat", volume: 0.9)
            impact(.light)
            after(0.38) {
                self.sound("signal", volume: 0.75)
                self.impact(.light, intensity: 0.7)
            }
        case .heartSync:
            duckMusic(for: 2.2)
            sound("bell", volume: 0.85)
            heartbeatPair(delay: 0.1)
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    // MARK: Background music

    /// Call once the user is signed in and inside the app. Fades the loop in.
    func startMusic() {
        musicWanted = true
        updateMusic()
    }

    /// Call when the user leaves the main app (sign-out, account deletion). Fades out and rewinds.
    func stopMusic() {
        musicWanted = false
        updateMusic()
    }

    /// Pauses the loop whenever the scene isn't active (app switcher, Control Center, background).
    func sceneDidChange(active: Bool) {
        sceneActive = active
        updateMusic()
    }

    private var shouldPlayMusic: Bool { musicWanted && musicEnabled && sceneActive }

    private func updateMusic() {
        if shouldPlayMusic {
            guard let player = musicPlayer() else { return }
            if !player.isPlaying {
                player.volume = 0
                player.play()
            }
            player.setVolume(Self.musicVolume, fadeDuration: 1.5)
        } else if let player = music, player.isPlaying {
            guard sceneActive else {
                // Leaving the foreground: don't rely on a fade finishing while suspended.
                player.pause()
                return
            }
            player.setVolume(0, fadeDuration: 0.6)
            after(0.65) { [weak self] in
                guard let self, !self.shouldPlayMusic else { return }
                self.music?.pause()
                if !self.musicWanted { self.music?.currentTime = 0 }
            }
        }
    }

    private func musicPlayer() -> AVAudioPlayer? {
        if let music { return music }
        configureIfNeeded()
        guard let url = Bundle.main.url(forResource: "bgm", withExtension: "mp3"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.numberOfLoops = -1
        player.volume = 0
        player.prepareToPlay()
        music = player
        return player
    }

    /// Briefly lowers the music so a moment sound (the match bell) stands out.
    private func duckMusic(for seconds: TimeInterval) {
        guard let player = music, player.isPlaying else { return }
        player.setVolume(Self.musicVolume * 0.3, fadeDuration: 0.3)
        after(seconds) { [weak self] in
            guard let self, self.shouldPlayMusic else { return }
            self.music?.setVolume(Self.musicVolume, fadeDuration: 1.0)
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
