import Foundation
import UIKit
import UserNotifications

/// Where a notification should take the user once the app is open and authenticated.
nonisolated enum NotificationRoute: Equatable, Sendable {
    case signals
    case around
    case match(UUID)

    /// Parses the `route` field sent by push-dispatch ("signals", "around", "match:<uuid>").
    init?(_ raw: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw == "signals" { self = .signals; return }
        if raw == "around" { self = .around; return }
        if raw.hasPrefix("match:"), let id = UUID(uuidString: String(raw.dropFirst("match:".count))) {
            self = .match(id)
            return
        }
        return nil
    }
}

/// Owns notification permission, APNs registration and the local Pulse-expiry reminder.
/// Remote delivery itself happens server-side (supabase/functions/push-dispatch).
final class PushManager: NSObject {
    static let shared = PushManager()

    enum Permission: Equatable { case notDetermined, denied, allowed }

    private(set) var permission: Permission = .notDetermined
    private(set) var deviceToken: String?
    /// Set by AppState so tokens and taps reach the backend / router.
    var onToken: ((String) -> Void)?
    var onRoute: ((NotificationRoute) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private let pulseReminderID = "crushly.pulse-expiring"

    func configure() {
        center.delegate = self
    }

    func refreshPermission() async -> Permission {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: permission = .notDetermined
        case .denied: permission = .denied
        default:
            permission = .allowed
            UIApplication.shared.registerForRemoteNotifications()
        }
        return permission
    }

    /// Shows the system prompt. Call only after the user chose to enable alerts in our own UI.
    @discardableResult
    func requestPermission() async -> Permission {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        permission = granted ? .allowed : .denied
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        return permission
    }

    func didRegister(token data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        onToken?(token)
    }

    /// Without the Push Notifications capability / APNs setup this fails; local reminders still work.
    func didFailToRegister(_ error: Error) {
        deviceToken = nil
        #if DEBUG
        print("[push] remote registration unavailable: \(error.localizedDescription)")
        #endif
    }

    // MARK: Local Pulse reminder

    /// Schedules "Your Pulse ends in 5 minutes" on-device. Used when there is no remote push token,
    /// so users aren't reminded twice once server push is live.
    func schedulePulseReminder(expiresAt: Date, enabled: Bool) {
        center.removePendingNotificationRequests(withIdentifiers: [pulseReminderID])
        guard enabled, deviceToken == nil, permission == .allowed else { return }
        let fireAt = expiresAt.addingTimeInterval(-5 * 60)
        guard fireAt > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Crushly"
        content.body = "Your Pulse ends in 5 minutes."
        content.sound = .default
        content.userInfo = ["route": "around"]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireAt.timeIntervalSinceNow, repeats: false)
        center.add(UNNotificationRequest(identifier: pulseReminderID, content: content, trigger: trigger))
    }

    func cancelPulseReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [pulseReminderID])
    }
}

extension PushManager: UNUserNotificationCenterDelegate {
    /// In the foreground the app's own UI (badges, reveal) already shows what changed, so system
    /// banners are suppressed except for time-sensitive reminders.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        let route = notification.request.content.userInfo["route"] as? String
        return route == "around" ? [.banner, .sound] : []
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo["route"] as? String
        guard let route = NotificationRoute(raw) else { return }
        await MainActor.run { PushManager.shared.onRoute?(route) }
    }
}

/// Bridges UIKit's remote-notification callbacks into SwiftUI.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PushManager.shared.configure()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushManager.shared.didRegister(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushManager.shared.didFailToRegister(error)
    }
}
