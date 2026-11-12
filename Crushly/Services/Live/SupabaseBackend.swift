import Foundation
import Supabase

/// Live backend. Every sensitive rule is enforced by the SQL functions in supabase/migrations;
/// this type only translates between RPC payloads and domain models. Uses only the anon key.
final class SupabaseBackend: CrushlyBackend {
    private let client: SupabaseClient
    private let photoBucket = "profile-photos"
    private var signedURLCache: [String: (url: URL, expires: Date)] = [:]

    init(url: URL, anonKey: String) {
        client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: anonKey,
            options: SupabaseClientOptions(auth: .init(emitLocalSessionAsInitialSession: true))
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

    func requestCode(email: String) async throws {
        do {
            try await client.auth.signInWithOTP(email: email, shouldCreateUser: true)
        } catch {
            // The allowed-domain trigger rejects the insert; GoTrue surfaces it as a database error.
            if "\(error)".localizedCaseInsensitiveContains("database error") { throw CrushlyError.domainNotAllowed }
            throw map(error)
        }
    }

    func verifyCode(email: String, code: String) async throws {
        do {
            _ = try await client.auth.verifyOTP(email: email, token: code, type: .email)
        } catch is AuthError {
            throw CrushlyError.invalidVerificationCode
        }
    }

    #if DEBUG
    /// DEV ONLY — remove before launch. Signs in with a fixed password instead of an emailed code,
    /// creating the account on first use. Needs "Confirm email" turned off in Supabase Auth
    /// (otherwise sign-up returns no session). Accounts first created via OTP have no password
    /// and can't use this path.
    private static let devPassword = "crushly-dev-bypass-password"

    func devSignIn(email: String) async throws {
        do {
            _ = try await client.auth.signIn(email: email, password: Self.devPassword)
            return
        } catch {
            // Fall through to sign-up when the account doesn't exist yet.
        }
        do {
            let response = try await client.auth.signUp(email: email, password: Self.devPassword)
            guard response.session != nil else {
                throw CrushlyError.unknown("dev sign-up returned no session — disable \"Confirm email\" in Supabase Auth")
            }
        } catch let error as CrushlyError {
            throw error
        } catch {
            if "\(error)".localizedCaseInsensitiveContains("database error") { throw CrushlyError.domainNotAllowed }
            throw CrushlyError.unknown("dev sign-in failed: \(error.localizedDescription)")
        }
    }
    #endif

    func signOut() async throws {
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
            account: state.privateAccount?.domain ?? PrivateAccount(),
            pulse: state.pulse?.domain,
            shield: state.shield?.domain,
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

    func savePrivate(instagramHandle: String, verifiedOnlyDiscovery: Bool) async throws {
        nonisolated struct Row: Encodable { let user_id: UUID; let instagram_handle: String; let verified_only_discovery: Bool }
        do {
            try await client.from("profile_private")
                .update(Row(user_id: try uid, instagram_handle: instagramHandle, verified_only_discovery: verifiedOnlyDiscovery))
                .eq("user_id", value: try uid)
                .execute()
        } catch {
            throw map(error)
        }
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

    func spaces() async throws -> [CampusSpace] {
        do {
            let rows: [SpaceDTO] = try await client.from("campus_spaces")
                .select().eq("is_active", value: true).order("sort_order").execute().value
            return rows.map(\.domain)
        } catch {
            throw map(error)
        }
    }

    func enterSpaceCode(_ code: String) async throws -> CampusSpace {
        nonisolated struct Params: Encodable { let code: String }
        let space: SpaceDTO = try await call("enter_space_code", Params(code: code))
        return space.domain
    }

    // MARK: PulseService

    func startPulse(spaceID: UUID, durationMinutes: Int?, untilEventEnd: Bool, availability: Availability) async throws -> PulseSession {
        nonisolated struct Params: Encodable { let space_id: UUID; let duration_minutes: Int?; let until_event_end: Bool; let availability: Availability }
        let session: SessionDTO = try await call("start_pulse", Params(space_id: spaceID, duration_minutes: durationMinutes,
                                                                        until_event_end: untilEventEnd, availability: availability))
        return session.domain
    }

    func pausePulse() async throws -> PulseSession {
        let session: SessionDTO = try await call("pause_pulse")
        return session.domain
    }

    func resumePulse() async throws -> PulseSession {
        let session: SessionDTO = try await call("resume_pulse")
        return session.domain
    }

    func endPulse() async throws { try await callVoid("end_pulse") }

    func aroundProfiles() async throws -> [PublicProfile] {
        let rows: [PublicProfileDTO] = try await call("around_profiles")
        return rows.map(\.domain)
    }

    func recentEncounters() async throws -> [PublicProfile] {
        let rows: [PublicProfileDTO] = try await call("recent_encounters")
        return rows.map(\.domain)
    }

    // MARK: SignalService

    func sendHeartSignal(to recipient: UUID) async throws -> SendSignalResult {
        nonisolated struct Params: Encodable { let recipient: UUID }
        nonisolated struct Result: Decodable { let result: String; let match_id: UUID?; let remaining: Int }
        let result: Result = try await call("send_heart_signal", Params(recipient: recipient))
        if result.result == "matched", let id = result.match_id {
            return .matched(matchID: id, remaining: result.remaining)
        }
        return .sent(remaining: result.remaining)
    }

    func receipts() async throws -> [SignalReceipt] {
        let rows: [ReceiptDTO] = try await call("my_signal_receipts")
        return rows.map { SignalReceipt(id: $0.id, receivedBucket: $0.received_bucket, spaceName: $0.space_name) }
    }

    func sentSignals() async throws -> [SentSignal] {
        let rows: [SentSignalDTO] = try await call("my_sent_signals")
        return rows.map {
            SentSignal(id: $0.id, recipient: $0.recipient.domain, createdAt: $0.created_at, expiresAt: $0.expires_at, status: $0.status)
        }
    }

    // MARK: MatchService

    func matches() async throws -> [Match] {
        let rows: [MatchDTO] = try await call("my_matches")
        return rows.map(\.domain)
    }

    func setConnectionStatus(matchID: UUID, status: ConnectionStatus) async throws {
        nonisolated struct Params: Encodable { let match_id: UUID; let status: ConnectionStatus }
        try await callVoid("set_connection_status", Params(match_id: matchID, status: status))
    }

    func sendConnectionAction(matchID: UUID, kind: ConnectionActionKind, detail: String?) async throws {
        nonisolated struct Payload: Encodable { let detail: String? }
        nonisolated struct Params: Encodable { let match_id: UUID; let kind: ConnectionActionKind; let payload: Payload }
        try await callVoid("send_connection_action", Params(match_id: matchID, kind: kind, payload: Payload(detail: detail)))
    }

    func respondConnectionAction(actionID: UUID, accept: Bool) async throws {
        nonisolated struct Params: Encodable { let action_id: UUID; let accept: Bool }
        try await callVoid("respond_connection_action", Params(action_id: actionID, accept: accept))
    }

    func instagramHandle(matchID: UUID) async throws -> String? {
        nonisolated struct Params: Encodable { let match_id: UUID }
        let handle: String? = try await call("connection_instagram", Params(match_id: matchID))
        return handle
    }

    func requestFind(matchID: UUID, meetingPoint: String) async throws {
        nonisolated struct Params: Encodable { let match_id: UUID; let meeting_point: String }
        try await callVoid("request_find", Params(match_id: matchID, meeting_point: meetingPoint))
    }

    func respondFind(requestID: UUID, accept: Bool) async throws {
        nonisolated struct Params: Encodable { let request_id: UUID; let accept: Bool }
        try await callVoid("respond_find", Params(request_id: requestID, accept: accept))
    }

    func cancelFind(requestID: UUID) async throws {
        nonisolated struct Params: Encodable { let request_id: UUID }
        try await callVoid("cancel_find", Params(request_id: requestID))
    }

    func completeFind(requestID: UUID) async throws {
        nonisolated struct Params: Encodable { let request_id: UUID }
        try await callVoid("complete_find", Params(request_id: requestID))
    }

    // MARK: SafetyService

    func enterShield(durationMinutes: Int?) async throws -> ShieldState {
        nonisolated struct Params: Encodable { let duration_minutes: Int? }
        let row: ShieldDTO = try await call("enter_shield", Params(duration_minutes: durationMinutes))
        return row.domain
    }

    func exitShield() async throws { try await callVoid("exit_shield") }

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

    func report(userID: UUID, category: ReportCategory, details: String) async throws {
        nonisolated struct Context: Encodable { let source = "ios" }
        nonisolated struct Params: Encodable { let target: UUID; let category: ReportCategory; let details: String; let context: Context }
        let _: UUID = try await call("report_user", Params(target: userID, category: category, details: details, context: Context()))
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

    func track(_ event: AnalyticsEvent) async {
        nonisolated struct Props: Encodable {}
        nonisolated struct Params: Encodable { let name: String; let props: Props }
        try? await callVoid("track_event", Params(name: event.rawValue, props: Props()))
    }
}
