import Foundation

// Service contracts shared by the demo and live (Supabase) backends.
// Each protocol mirrors a group of RPCs in docs/BACKEND_CONTRACT.md §4. Sensitive rules are enforced behind these
// calls (in SQL for live, mirrored in DemoBackend for the dev fixture), never in views.

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
    func saveVerifiedOnlyDiscovery(_ enabled: Bool) async throws
    /// `update_match_preferences`. Required before participating.
    func updateMatchPreferences(_ preferences: MatchPreferences) async throws
    func acceptTerms(termsVersion: String, privacyVersion: String, ageConfirmed: Bool) async throws
    /// Uploads JPEG data and returns the stored path. New photos enter review as `pending`.
    func uploadPhoto(_ jpeg: Data) async throws -> String
    func deletePhoto(path: String) async throws
    /// A short-lived URL for displaying a stored photo, or nil when the path is not a remote photo.
    func photoURL(for path: String) async -> URL?
}

protocol SpaceService: AnyObject {
    /// Supported spaces the server currently allows (`campus_spaces`, filtered by RLS).
    func zones() async throws -> [SpaceZone]
}

protocol ParticipationService: AnyObject {
    func myParticipation() async throws -> ParticipationStatus
    func openParticipation(spaceSlug: String, boundaryVersion: Int, consentEpoch: Int64, clientRequestID: UUID,
                           evidence: LocationEvidence) async throws -> ParticipationLease
    func renewParticipation(sessionID: UUID, seq: Int64, evidence: LocationEvidence) async throws -> ParticipationLease
    /// Idempotent. Returns the new consent epoch.
    @discardableResult func revokeParticipation() async throws -> Int64
    /// Pausing revokes; resuming never opens a session. `minutes` nil = until resumed.
    func setMatchingPaused(_ paused: Bool, minutes: Int?) async throws -> ParticipationStatus
}

protocol DiscoveryService: AnyObject {
    func discoverCandidates() async throws -> DiscoveryResult
    func expressInterest(in target: UUID) async throws -> InterestResult
    /// How many people in this visit anonymously expressed interest. No ids, times or places.
    func interestReceipts() async throws -> Int
    func sentInterests() async throws -> Set<UUID>
}

protocol ConversationService: AnyObject {
    func conversations() async throws -> [Conversation]
    /// Newest first. Pass the oldest message you have as `before` to page back.
    func fetchMessages(matchID: UUID, before: MessageCursor?, limit: Int) async throws -> [ChatMessage]
    /// Retry-safe: the same `clientMessageID` never creates a second message.
    func sendMessage(matchID: UUID, clientMessageID: UUID, body: String) async throws -> SentMessageReceipt
    func markConversationRead(matchID: UUID) async throws
    /// Ends the match and deletes the conversation for both people.
    func leaveConversation(matchID: UUID) async throws
}

protocol SafetyService: AnyObject {
    func block(userID: UUID) async throws
    func unblock(userID: UUID) async throws
    func blockedUsers() async throws -> [BlockedUser]
    /// Copies only the selected messages as evidence, then blocks (which deletes the conversation).
    func report(userID: UUID, category: ReportCategory, details: String, evidenceMessageIDs: [UUID]) async throws
}

protocol NotificationService: AnyObject {
    func updatePrefs(_ prefs: NotificationPrefs) async throws
    func registerDevice(token: String, sandbox: Bool) async throws
    func unregisterDevice(token: String) async throws
}

/// A content-free "something changed" signal from the user's private channel (`user:<uid>`). Never carries message
/// text; the app always refetches through the participant-checked RPCs.
nonisolated struct RealtimePoke: Equatable, Sendable {
    enum Kind: String, Sendable { case message, match, conversationRemoved = "conversation_removed" }
    var kind: Kind
    var matchID: UUID?
}

protocol RealtimeService: AnyObject {
    /// Subscribes to the caller's private channel, replacing any previous subscription.
    func startPokes(userID: UUID) async -> AsyncStream<RealtimePoke>
    func stopPokes() async
}

protocol AnalyticsService: AnyObject {
    /// Allow-listed product events only. Never location, presence, interest, match or message events.
    func track(_ event: AnalyticsEvent) async
}

/// Mirrors the server allow-list (`app_settings.analytics_allowed_events`). Deliberately has no participation,
/// interest or match events: those would form a record of where someone was.
nonisolated enum AnalyticsEvent: String, Sendable, CaseIterable {
    case appOpen = "app_open"
    case onboardingCompleted = "onboarding_completed"
    case profileUpdated = "profile_updated"
    case photoUploaded = "photo_uploaded"
    case conversationLeft = "conversation_left"
    case userBlocked = "user_blocked"
    case userUnblocked = "user_unblocked"
    case userReported = "user_reported"
    case notificationOpened = "notification_opened"
    case notificationPrefsChanged = "notification_prefs_changed"
    case accountDeleted = "account_deleted"
}

typealias CrushlyBackend = AuthService & ProfileService & SpaceService & ParticipationService & DiscoveryService
    & ConversationService & SafetyService & NotificationService & RealtimeService & AnalyticsService
