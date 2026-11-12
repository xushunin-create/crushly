import Foundation

// Service contracts shared by the demo and live (Supabase) backends.
// Each protocol mirrors a group of RPCs in docs/BACKEND_CONTRACT.md. Sensitive rules are
// enforced behind these calls (in SQL for live, in DemoRules for demo) — never in views.

protocol AuthService: AnyObject {
    /// Restores a persisted session, if any. Returns the signed-in user's email.
    func restoreSession() async -> String?
    /// Sends a one-time sign-in code. Creates the account on first use (passwordless).
    func requestCode(email: String) async throws
    func verifyCode(email: String, code: String) async throws
    #if DEBUG
    /// DEV ONLY — skips the emailed code. Remove before launch.
    func devSignIn(email: String) async throws
    #endif
    func signOut() async throws
    /// Permanently deletes the account, photos and dependent records (server-side).
    func deleteAccount() async throws
}

protocol ProfileService: AnyObject {
    func loadAccount() async throws -> AccountSnapshot
    func saveProfile(_ profile: Profile) async throws -> Profile
    func savePrivate(instagramHandle: String, verifiedOnlyDiscovery: Bool) async throws
    func acceptTerms(termsVersion: String, privacyVersion: String, ageConfirmed: Bool) async throws
    /// Uploads JPEG data and returns the stored path. New photos enter review as `pending`.
    func uploadPhoto(_ jpeg: Data) async throws -> String
    func deletePhoto(path: String) async throws
    /// A short-lived URL for displaying a stored photo, or nil when the path is not a remote photo.
    func photoURL(for path: String) async -> URL?
}

protocol SpaceService: AnyObject {
    func spaces() async throws -> [CampusSpace]
    func enterSpaceCode(_ code: String) async throws -> CampusSpace
}

protocol PulseService: AnyObject {
    func startPulse(spaceID: UUID, durationMinutes: Int?, untilEventEnd: Bool, availability: Availability) async throws -> PulseSession
    func pausePulse() async throws -> PulseSession
    func resumePulse() async throws -> PulseSession
    func endPulse() async throws
    func aroundProfiles() async throws -> [PublicProfile]
    func recentEncounters() async throws -> [PublicProfile]
}

protocol SignalService: AnyObject {
    func sendHeartSignal(to recipient: UUID) async throws -> SendSignalResult
    func receipts() async throws -> [SignalReceipt]
    func sentSignals() async throws -> [SentSignal]
}

protocol MatchService: AnyObject {
    func matches() async throws -> [Match]
    func setConnectionStatus(matchID: UUID, status: ConnectionStatus) async throws
    func sendConnectionAction(matchID: UUID, kind: ConnectionActionKind, detail: String?) async throws
    func respondConnectionAction(actionID: UUID, accept: Bool) async throws
    func instagramHandle(matchID: UUID) async throws -> String?
    func requestFind(matchID: UUID, meetingPoint: String) async throws
    func respondFind(requestID: UUID, accept: Bool) async throws
    func cancelFind(requestID: UUID) async throws
    func completeFind(requestID: UUID) async throws
}

protocol SafetyService: AnyObject {
    func enterShield(durationMinutes: Int?) async throws -> ShieldState
    func exitShield() async throws
    func block(userID: UUID) async throws
    func unblock(userID: UUID) async throws
    func blockedUsers() async throws -> [BlockedUser]
    func report(userID: UUID, category: ReportCategory, details: String) async throws
}

protocol NotificationService: AnyObject {
    func updatePrefs(_ prefs: NotificationPrefs) async throws
    func registerDevice(token: String, sandbox: Bool) async throws
}

protocol AnalyticsService: AnyObject {
    /// Allow-listed product events only. Never include location or profile content.
    func track(_ event: AnalyticsEvent) async
}

nonisolated enum AnalyticsEvent: String, Sendable {
    case onboardingCompleted = "onboarding_completed"
    case pulseStarted = "pulse_started"
    case signalSent = "signal_sent"
    case matchViewed = "match_viewed"
    case connectionActionSent = "connection_action_sent"
    case findRequested = "find_requested"
    case shieldEntered = "shield_entered"
}

typealias CrushlyBackend = AuthService & ProfileService & SpaceService & PulseService & SignalService
    & MatchService & SafetyService & NotificationService & AnalyticsService
