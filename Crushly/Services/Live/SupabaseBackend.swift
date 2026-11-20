import Foundation
import Supabase

/// Live backend. Every sensitive rule is enforced by the SQL functions in supabase/migrations;
/// this type only translates between RPC payloads and domain models. Uses only the anon key.
final class SupabaseBackend: CrushlyBackend {
    let client: SupabaseClient
    private let photoBucket = "profile-photos"
    private var signedURLCache: [String: (url: URL, expires: Date)] = [:]
    private var pokeChannel: RealtimeChannelV2?

    init(url: URL, anonKey: String) {
        client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: anonKey,
            options: SupabaseClientOptions(auth: .init(
                storage: SessionKeychainStorage(),
                emitLocalSessionAsInitialSession: true
            ))
        )
    }

    // MARK: Helpers

    private nonisolated struct Empty: Encodable, Sendable {}

    private func call<T: Decodable & Sendable>(_ fn: String, _ params: some Encodable & Sendable = Empty()) async throws -> T {
        do {
            return try await client.rpc(fn, params: params).execute().value
        } catch {
            throw map(error)
        }
    }

    private func callVoid(_ fn: String, _ params: some Encodable & Sendable = Empty()) async throws {
        do {
            try await client.rpc(fn, params: params).execute()
        } catch {
            throw map(error)
        }
    }

    private func map(_ error: Error) -> Error {
        if let postgrest = error as? PostgrestError {
            let code = CrushlyError(serverCode: postgrest.message)
            if case .unknown = code, postgrest.code == "PGRST301" || postgrest.message.contains("JWT") {
                return CrushlyError.notAuthenticated
            }
            return code
        }
        if error is URLError { return error }
        if let auth = error as? AuthError, case .sessionMissing = auth { return CrushlyError.notAuthenticated }
        return error
    }

    private var uid: UUID {
        get throws {
            guard let id = client.auth.currentUser?.id else { throw CrushlyError.notAuthenticated }
            return id
        }
    }

    // MARK: AuthService

    func restoreSession() async -> String? {
        guard let session = try? await client.auth.session, !session.isExpired else { return nil }
        return session.user.email
    }

    /// The one App Review account. No email is sent for it; the reviewer types the fixed code from
    /// App Review Information, which `review-sign-in` checks server-side (REVIEW_EMAIL / REVIEW_CODE secrets).
    static let appReviewEmail = "crushly-appreview@usc.edu"

    private nonisolated struct ReviewSignInRequest: Encodable, Sendable { let email: String; let code: String }
    private nonisolated struct ReviewSignInTokens: Decodable, Sendable {
        let accessToken: String
        let refreshToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token" }
    }

    func requestCode(email: String, createAccount: Bool) async throws {
        if email == Self.appReviewEmail { return }
        do {
            try await client.auth.signInWithOTP(email: email, shouldCreateUser: createAccount)
        } catch AuthError.api(_, let code, _, _) where !createAccount
                    && [.otpDisabled, .signupDisabled, .userNotFound].contains(code) {
            // GoTrue refuses to create the user ("Signups not allowed for otp"): no account for this address.
            throw CrushlyError.accountNotFound
        } catch {
            // The allowed-domain trigger rejects the insert; GoTrue surfaces it as a database error.
            if "\(error)".localizedCaseInsensitiveContains("database error") { throw CrushlyError.domainNotAllowed }
            throw map(error)
        }
    }

    func verifyCode(email: String, code: String) async throws {
        if email == Self.appReviewEmail {
            try await reviewSignIn(email: email, code: code)
            return
        }
        do {
            _ = try await client.auth.verifyOTP(email: email, token: code, type: .email)
        } catch is AuthError {
            throw CrushlyError.invalidVerificationCode
        }
    }

    private func reviewSignIn(email: String, code: String) async throws {
        let tokens: ReviewSignInTokens
        do {
            tokens = try await client.functions.invoke(
                "review-sign-in",
                options: FunctionInvokeOptions(method: .post, body: ReviewSignInRequest(email: email, code: code))
            )
        } catch FunctionsError.httpError(let status, _) {
            throw status == 429 ? CrushlyError.rateLimited : CrushlyError.invalidVerificationCode
        }
        try await client.auth.setSession(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken)
    }

    func signOut() async throws {
        await stopPokes()
        try await client.auth.signOut(scope: .local)
    }

    func deleteAccount() async throws {
        // Runs with the service role inside the edge function; the client only proves who it is.
        try await client.functions.invoke("delete-account", options: FunctionInvokeOptions(method: .post))
        try? await client.auth.signOut(scope: .local)
    }

    // MARK: ProfileService

    func loadAccount() async throws -> AccountSnapshot {
        let state: StateDTO = try await call("my_state")
        let id = try uid
        return AccountSnapshot(
            userID: id,
            email: client.auth.currentUser?.email ?? "",
            profile: state.profile?.domain,
            account: state.privateAccount?.account ?? PrivateAccount(),
            preferences: state.privateAccount?.preferences ?? MatchPreferences(),
            prefs: state.prefs?.domain ?? NotificationPrefs(),
            rules: state.settings?.domain ?? .default,
            serverNow: state.serverNow ?? Date()
        )
    }

    func saveProfile(_ profile: Profile) async throws -> Profile {
        nonisolated struct Params: Encodable { let p: ProfileDTO }
        let saved: ProfileDTO = try await call("upsert_profile", Params(p: ProfileDTO(profile)))
        return saved.domain
    }

    func saveVerifiedOnlyDiscovery(_ enabled: Bool) async throws {
        // Column-level grant: authenticated may update only verified_only_discovery on its own row (RLS).
        nonisolated struct Row: Encodable { let verified_only_discovery: Bool }
        do {
            try await client.from("profile_private")
                .update(Row(verified_only_discovery: enabled))
                .eq("user_id", value: try uid)
                .execute()
        } catch {
            throw map(error)
        }
    }

    func updateMatchPreferences(_ preferences: MatchPreferences) async throws {
        nonisolated struct Params: Encodable {
            let p_match_gender: String?; let p_show_me: [String]; let p_age_min: Int; let p_age_max: Int
        }
        try await callVoid("update_match_preferences", Params(
            p_match_gender: preferences.matchGender?.rawValue,
            p_show_me: preferences.showMe.sorted().map(\.rawValue),
            p_age_min: preferences.ageMin, p_age_max: preferences.ageMax))
    }

    func acceptTerms(termsVersion: String, privacyVersion: String, ageConfirmed: Bool) async throws {
        nonisolated struct Params: Encodable { let terms_version: String; let privacy_version: String; let age_confirmed: Bool }
        try await callVoid("accept_terms", Params(terms_version: termsVersion, privacy_version: privacyVersion, age_confirmed: ageConfirmed))
    }

    func uploadPhoto(_ jpeg: Data) async throws -> String {
        let path = "\(try uid.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        do {
            _ = try await client.storage.from(photoBucket)
                .upload(path, data: jpeg, options: FileOptions(contentType: "image/jpeg", upsert: false))
        } catch {
            throw map(error)
        }
        return path
    }

    func deletePhoto(path: String) async throws {
        _ = try await client.storage.from(photoBucket).remove(paths: [path])
    }

    func photoURL(for path: String) async -> URL? {
        guard !path.hasPrefix("avatar:") else { return nil }
        if let cached = signedURLCache[path], cached.expires > Date() { return cached.url }
        guard let url = try? await client.storage.from(photoBucket).createSignedURL(path: path, expiresIn: 3600) else { return nil }
        signedURLCache[path] = (url, Date().addingTimeInterval(3000))
        return url
    }

    // MARK: SpaceService

    func zones() async throws -> [SpaceZone] {
        do {
            // RLS returns only enabled spaces that are field-validated (or drafts when allow_draft_spaces is on).
            let rows: [SpaceZone] = try await client.from("campus_spaces")
                .select("slug,name,subtitle,boundary,boundary_version,validation_status,enabled,sort_order,membership_rule,max_accuracy_m")
                .order("sort_order").execute().value
            return rows.sorted { ($0.sortOrder, $0.slug) < ($1.sortOrder, $1.slug) }
        } catch {
            throw map(error)
        }
    }

    // MARK: ParticipationService

    func myParticipation() async throws -> ParticipationStatus {
        let dto: ParticipationDTO = try await call("my_participation")
        return dto.domain
    }

    func openParticipation(spaceSlug: String, boundaryVersion: Int, consentEpoch: Int64, clientRequestID: UUID,
                           evidence: LocationEvidence) async throws -> ParticipationLease {
        nonisolated struct Params: Encodable {
            let p_space_slug: String; let p_boundary_version: Int; let p_consent_epoch: Int64
            let p_client_request_id: UUID; let p_evidence: EvidenceDTO
        }
        let dto: LeaseDTO = try await call("open_participation", Params(
            p_space_slug: spaceSlug, p_boundary_version: boundaryVersion, p_consent_epoch: consentEpoch,
            p_client_request_id: clientRequestID, p_evidence: EvidenceDTO(evidence)))
        return dto.domain
    }

    func renewParticipation(sessionID: UUID, seq: Int64, evidence: LocationEvidence) async throws -> ParticipationLease {
        nonisolated struct Params: Encodable { let p_session_id: UUID; let p_seq: Int64; let p_evidence: EvidenceDTO }
        let dto: LeaseDTO = try await call("renew_participation",
                                           Params(p_session_id: sessionID, p_seq: seq, p_evidence: EvidenceDTO(evidence)))
        return dto.domain
    }

    @discardableResult
    func revokeParticipation() async throws -> Int64 {
        try await call("revoke_participation")
    }

    func setMatchingPaused(_ paused: Bool, minutes: Int?) async throws -> ParticipationStatus {
        nonisolated struct Params: Encodable { let p_paused: Bool; let p_minutes: Int? }
        let dto: ParticipationDTO = try await call("set_matching_paused", Params(p_paused: paused, p_minutes: minutes))
        return dto.domain
    }

    // MARK: DiscoveryService

    func discoverCandidates() async throws -> DiscoveryResult {
        let dto: DiscoveryDTO = try await call("discover_candidates")
        return dto.domain
    }

    func expressInterest(in target: UUID) async throws -> InterestResult {
        nonisolated struct Params: Encodable { let p_target: UUID }
        let dto: InterestDTO = try await call("express_interest", Params(p_target: target))
        return dto.domain
    }

    func interestReceipts() async throws -> Int {
        try await call("my_interest_receipts")
    }

    func sentInterests() async throws -> Set<UUID> {
        let ids: [UUID] = try await call("my_sent_interests")
        return Set(ids)
    }

    // MARK: ConversationService

    func conversations() async throws -> [Conversation] {
        let rows: [ConversationDTO] = try await call("my_conversations")
        return rows.map(\.domain)
    }

    func fetchMessages(matchID: UUID, before: MessageCursor?, limit: Int) async throws -> [ChatMessage] {
        nonisolated struct Params: Encodable {
            let p_match_id: UUID; let p_before_created_at: String?; let p_before_id: UUID?; let p_limit: Int
        }
        let rows: [MessageDTO] = try await call("fetch_messages", Params(
            p_match_id: matchID, p_before_created_at: before.map { PreciseTimestamp.format($0.createdAt) },
            p_before_id: before?.id, p_limit: limit))
        return rows.map(\.domain)
    }

    func sendMessage(matchID: UUID, clientMessageID: UUID, body: String) async throws -> SentMessageReceipt {
        nonisolated struct Params: Encodable { let p_match_id: UUID; let p_client_message_id: UUID; let p_body: String }
        let rows: [SentMessageDTO] = try await call("send_message",
                                                    Params(p_match_id: matchID, p_client_message_id: clientMessageID, p_body: body))
        guard let row = rows.first else { throw CrushlyError.notFound }
        return SentMessageReceipt(id: row.id, createdAt: row.created_at)
    }

    func markConversationRead(matchID: UUID) async throws {
        nonisolated struct Params: Encodable { let p_match_id: UUID }
        try await callVoid("mark_conversation_read", Params(p_match_id: matchID))
    }

    func leaveConversation(matchID: UUID) async throws {
        nonisolated struct Params: Encodable { let p_match_id: UUID }
        try await callVoid("leave_conversation", Params(p_match_id: matchID))
    }

    // MARK: SafetyService

    func block(userID: UUID) async throws {
        nonisolated struct Params: Encodable { let target: UUID }
        try await callVoid("block_user", Params(target: userID))
    }

    func unblock(userID: UUID) async throws {
        nonisolated struct Params: Encodable { let target: UUID }
        try await callVoid("unblock_user", Params(target: userID))
    }

    func blockedUsers() async throws -> [BlockedUser] {
        nonisolated struct Row: Decodable { let user_id: UUID; let first_name: String?; let created_at: Date }
        let rows: [Row] = try await call("my_blocks")
        return rows.map { BlockedUser(id: $0.user_id, firstName: $0.first_name ?? "Someone", blockedAt: $0.created_at) }
    }

    func report(userID: UUID, category: ReportCategory, details: String, evidenceMessageIDs: [UUID]) async throws {
        nonisolated struct Params: Encodable {
            let target: UUID; let category: ReportCategory; let details: String?; let evidence_message_ids: [UUID]
        }
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let _: UUID = try await call("report_user", Params(target: userID, category: category,
                                                           details: trimmed.isEmpty ? nil : trimmed,
                                                           evidence_message_ids: evidenceMessageIDs))
    }

    // MARK: RealtimeService

    func startPokes(userID: UUID) async -> AsyncStream<RealtimePoke> {
        await stopPokes()
        // auth.uid()::text is lowercase; the RLS policy compares topics exactly.
        let channel = client.channel("user:\(userID.uuidString.lowercased())") { $0.isPrivate = true }
        pokeChannel = channel
        let raw = channel.broadcastStream(event: "poke")   // register before subscribing
        do {
            try await channel.subscribeWithError()
        } catch {
            // Realtime is best effort: the app still refetches on launch, foreground and a light poll.
        }
        return AsyncStream { continuation in
            let task = Task {
                for await message in raw {
                    if let poke = Self.parsePoke(message) { continuation.yield(poke) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stopPokes() async {
        guard let channel = pokeChannel else { return }
        pokeChannel = nil
        await client.removeChannel(channel)
    }

    /// Accepts the broadcast envelope or the bare payload. Anything but {type, match_id} is ignored.
    nonisolated static func parsePoke(_ message: JSONObject) -> RealtimePoke? {
        let body = message["payload"]?.objectValue ?? message
        guard let kind = body["type"]?.stringValue.flatMap(RealtimePoke.Kind.init(rawValue:)) else { return nil }
        return RealtimePoke(kind: kind, matchID: body["match_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
    }

    // MARK: NotificationService / AnalyticsService

    func updatePrefs(_ prefs: NotificationPrefs) async throws {
        nonisolated struct Params: Encodable { let p: PrefsDTO }
        try await callVoid("update_notification_prefs", Params(p: PrefsDTO(prefs)))
    }

    func registerDevice(token: String, sandbox: Bool) async throws {
        nonisolated struct Params: Encodable { let token: String; let platform: String; let apns_env: String }
        try await callVoid("register_device", Params(token: token, platform: "ios", apns_env: sandbox ? "sandbox" : "production"))
    }

    func unregisterDevice(token: String) async throws {
        nonisolated struct Params: Encodable { let token: String }
        try await callVoid("unregister_device", Params(token: token))
    }

    func track(_ event: AnalyticsEvent) async {
        nonisolated struct Props: Encodable {}
        nonisolated struct Params: Encodable { let name: String; let props: Props }
        try? await callVoid("track_event", Params(name: event.rawValue, props: Props()))
    }
}
