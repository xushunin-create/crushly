import Foundation
import UIKit
import UserNotifications

/// Where a notification should take the user once the app is open and authenticated.
/// Opening a notification only navigates; it never grants consent or changes visibility.
nonisolated enum NotificationRoute: Equatable, Sendable {
    case connections
    case match(UUID)

    /// Parses the `route` field sent by push-dispatch ("connections", "match:<uuid>").
    init?(_ raw: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw == "connections" { self = .connections; return }
        if raw.hasPrefix("match:"), let id = UUID(uuidString: String(raw.dropFirst("match:".count))) {
            self = .match(id)
            return
        }
        return nil
    }
}

/// Owns notification permission and APNs registration.
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
}

extension PushManager: UNUserNotificationCenterDelegate {
    /// In the foreground the app's own UI (badges, reveal) already shows what changed, so system banners are suppressed.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        []
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
