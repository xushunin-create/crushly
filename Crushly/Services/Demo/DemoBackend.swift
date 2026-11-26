import Foundation
import UIKit

/// DEV FIXTURE — in-memory backend for demo mode (always shown with a DEMO badge). Implements the same contracts as
/// the live backend and mirrors the SQL rules in supabase/migrations/20261116000000_campus_spaces.sql
/// (docs/BACKEND_CONTRACT.md §3–4). All people are fictional; nothing is persisted or sent anywhere.
///
/// It is never a production check-in bypass: it can't talk to the server, and AppState only pairs it with the
/// simulated location provider (live mode always uses Core Location). Draft spaces are allowed here because this is
/// a dev fixture; the production server keeps `allow_draft_spaces = false`.
final class DemoBackend: CrushlyBackend {
    struct Options: Equatable {
        /// Start already signed in with a finished profile and preferences (skips onboarding).
        var seededAccount = false
        /// Anonymous receipt delay. The server uses 30–90 s; the demo defaults to a few seconds so it is testable.
        var receiptDelay: TimeInterval = 3
        /// How long scripted people take to reply to a message.
        var replyDelay: TimeInterval = 4
        var latency: Duration = .milliseconds(180)
        /// Mirror the server's fixed-window rate limits.
        var enforceRateLimits = true
    }

    // MARK: State

    private(set) var options: Options
    private(set) var rules: AppRules = {
        var rules = AppRules.default
        rules.allowDraftSpaces = true   // dev fixture only; see the type comment
        return rules
    }()
    let zones: [SpaceZone]
    /// Demo-only clock offset so leases and pauses can be tested without waiting ("Skip ahead" in Me › Demo).
    private(set) var clockOffset: TimeInterval = 0
    func now() -> Date { Date().addingTimeInterval(clockOffset) }

    let myID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    private var signedInEmail: String?
    private var pendingCodeEmail: String?
    private var profile: Profile?
    private var account = PrivateAccount()
    private var preferences = MatchPreferences()
    private var prefs = NotificationPrefs()
    private var photoStore: [String: Data] = [:]

    // participation_state + participation_sessions (mine)
    private var consentEpoch: Int64 = 0
    private var matchingPaused = false
    private var pausedUntil: Date?
    private var mySession: MySession?

    private var people: [UUID: DemoWorld.Person] = [:]
    /// Each fictional person's current session id (stable while they stay; removed when they leave).
    private var personSessions: [UUID: UUID] = [:]
    private var exposures: Set<SessionPair> = []
    private var interests: [Interest] = []
    private var matches: [UUID: DemoMatch] = [:]
    private var messages: [UUID: [DemoMessage]] = [:]
    private var replyCursor: [UUID: Int] = [:]
    private var blocks: Set<UserPair> = []
    private var blockedAt: [UUID: Date] = [:]
    private var rateHits: [String: Int] = [:]
    private var scheduled: [(at: Date, run: () -> Void)] = []
    private var departureScheduled = false

    private var pokeContinuation: AsyncStream<RealtimePoke>.Continuation?

    /// Fault injection (dev fixture / tests): the next N sends fail before reaching the "server".
    var simulateOfflineSends = 0
    /// Fault injection: the next N sends are stored, but the response is "lost" (the client sees a timeout).
    var simulateLostResponses = 0
    /// Fault injection: the next N photo uploads are refused as explicit.
    var simulateFlaggedPhotos = 0

    /// What the demo "moderators" received. Exposed for tests and the demo cast sheet.
    private(set) var submittedReports: [DemoReport] = []
    /// Ids only, like `deletion_tombstones`.
    private(set) var deletedMatchIDs: Set<UUID> = []

    private struct MySession {
        let id: UUID
        let slug: String
        let boundaryVersion: Int
        let consentEpoch: Int64
        let clientRequestID: UUID
        var leaseExpiresAt: Date
        var lastSeq: Int64
        var lastFixMs: Int64
        var interestsSent: Int
    }

    private struct SessionPair: Hashable { let viewer: UUID; let target: UUID }
    private struct UserPair: Hashable { let blocker: UUID; let blocked: UUID }

    private struct Interest {
        let sender: UUID      // session id
        let recipient: UUID   // session id
        let visibleAt: Date
    }

    private struct DemoMatch {
        let id: UUID
        let other: UUID
        let createdAt: Date
        var myLastReadAt: Date?
    }

    struct DemoMessage: Equatable {
        let id: UUID
        let senderID: UUID
        var body: String
        let createdAt: Date
        var kind: ChatMessage.Kind = .text
        var deleted = false
        var replyToID: UUID? = nil
        /// user id → emoji, one per person.
        var reactions: [UUID: String] = [:]
        var reactionOrder: [UUID] = []
    }

    struct DemoReport: Equatable {
        let target: UUID
        let category: ReportCategory
        let details: String?
        let evidence: [DemoMessage]
    }

    init(options: Options = Options(), zones: [SpaceZone] = SpaceZoneCatalog.bundled()) {
        self.options = options
        self.zones = zones
        for person in DemoWorld.people() {
            people[person.profile.id] = person
            if person.script.space != nil, !person.script.paused { personSessions[person.profile.id] = UUID() }
        }
        if options.seededAccount { seedAccount() }
    }

    private func seedAccount() {
        signedInEmail = "tommy@usc.edu"
        account = PrivateAccount(termsAcceptedVersion: LegalDocuments.termsVersion,
                                 privacyAcceptedVersion: LegalDocuments.privacyVersion, ageConfirmed: true)
        preferences = MatchPreferences(matchGender: .man, showMe: Set(MatchGender.allCases), ageMin: 18, ageMax: 120)
        profile = Profile(
            id: myID, firstName: "Tommy", age: 21, pronouns: "he/him", gender: "Man",
            interests: ["Music", "Design", "Coffee"], vibeTags: ["Night owl", "Deep talks"],
            promptQuestion: ProfilePrompts.all[1], promptAnswer: "McCarthy Quad with an iced latte.",
            intention: .figuringItOut, availability: .either, photoPaths: ["avatar:heart.fill|pink"],
            // A built-in placeholder avatar, not an uploaded photo, so it carries no checkmark. That keeps the
            // verified-only scenario (Sam) visible in the demo until you add a real photo.
            photoReviewStatus: .pending
        )
    }

    private func pause() async throws {
        if options.latency > .zero { try await Task.sleep(for: options.latency) }
        runDueScripts()
    }

    // MARK: Demo controls (not part of the service contracts)

    func skipAhead(minutes: Double) {
        clockOffset += minutes * 60
        runDueScripts()
    }

    /// Demo-only: simulates a moderator decision (e.g. removing photos after a report).
    func simulatePhotoReview(_ status: ReviewStatus) {
        profile?.photoReviewStatus = status
    }

    var scenarioNotes: [(name: String, note: String)] {
        people.values.sorted { $0.profile.id.uuidString < $1.profile.id.uuidString }
            .map { ($0.profile.firstName, $0.script.note) }
    }

    /// Demo-only: local image bytes for an uploaded demo photo.
    func demoPhotoData(for path: String) -> Data? { photoStore[path] }

    // MARK: Scripted behaviour

    private func schedule(after delay: TimeInterval, _ run: @escaping () -> Void) {
        scheduled.append((now().addingTimeInterval(delay), run))
    }

    private func runDueScripts() {
        expireLifecycle()
        while let index = scheduled.firstIndex(where: { $0.at <= now() }) {
            let item = scheduled.remove(at: index)
            item.run()
            expireLifecycle()
        }
    }

    /// The person "discovers" you and expresses interest, exactly as `express_interest` would for them.
    private func scriptedInterest(from person: UUID) {
        guard let me = mySession, me.leaseExpiresAt > now(), let theirs = personSessions[person],
              canMatch(person, myID), matchBetween(myID, person) == nil,
              !interests.contains(where: { $0.sender == theirs && $0.recipient == me.id }) else { return }
        exposures.insert(SessionPair(viewer: theirs, target: me.id))
        if let mine = interests.firstIndex(where: { $0.sender == me.id && $0.recipient == theirs }) {
            interests.remove(at: mine)
            createMatch(with: person)
        } else {
            interests.append(Interest(sender: theirs, recipient: me.id, visibleAt: now().addingTimeInterval(options.receiptDelay)))
        }
    }

    private func scriptedReply(in matchID: UUID) {
        guard let match = matches[matchID], !isBlockedBetween(myID, match.other),
              let lines = people[match.other]?.script.replies else { return }
        let index = replyCursor[match.other, default: 0]
        guard index < lines.count else { return }
        replyCursor[match.other] = index + 1
        // Their first reply hearts your latest message, like a tapback, and quotes it.
        let mineLatest = messages[matchID]?.last(where: { $0.senderID == myID && $0.kind == .text && !$0.deleted })
        if index == 0, let mineLatest, let at = messages[matchID]?.firstIndex(where: { $0.id == mineLatest.id }) {
            messages[matchID]?[at].reactions[match.other] = "❤️"
            messages[matchID]?[at].reactionOrder.append(match.other)
        }
        appendMessage(DemoMessage(id: UUID(), senderID: match.other, body: lines[index], createdAt: nextMessageTime(in: matchID),
                                  replyToID: index == 0 ? mineLatest?.id : nil),
                      to: matchID)
    }

    /// Mirror of crushly_tick + the lazy `lease_expires_at > now()` checks.
    private func expireLifecycle() {
        if let session = mySession, session.leaseExpiresAt <= now() {
            purgeSession(session.id)
            mySession = nil
        }
        if matchingPaused, let until = pausedUntil, until <= now() {
            matchingPaused = false
            pausedUntil = nil
        }
    }

    /// Deleting a session cascades to its interests and exposures (FK on delete cascade).
    private func purgeSession(_ id: UUID) {
        interests.removeAll { $0.sender == id || $0.recipient == id }
        exposures = exposures.filter { $0.viewer != id && $0.target != id }
    }

    private func personLeaves(_ person: UUID) {
        guard let session = personSessions.removeValue(forKey: person) else { return }
        purgeSession(session)
    }

    // MARK: Predicates (mirror of the SQL helpers)

    private struct ActiveSession { let id: UUID; let slug: String; let version: Int }

    private func activeSession(of user: UUID) -> ActiveSession? {
        if user == myID {
            guard let s = mySession, s.leaseExpiresAt > now() else { return nil }
            return ActiveSession(id: s.id, slug: s.slug, version: s.boundaryVersion)
        }
        guard let id = personSessions[user], let slug = people[user]?.script.space,
              let zone = zones.first(where: { $0.slug == slug }) else { return nil }
        return ActiveSession(id: id, slug: slug, version: zone.boundaryVersion)
    }

    private func owner(ofSession id: UUID) -> UUID? {
        if mySession?.id == id { return myID }
        return personSessions.first { $0.value == id }?.key
    }

    private func isPaused(_ user: UUID) -> Bool {
        if user == myID { return matchingPaused && (pausedUntil.map { $0 > now() } ?? true) }
        return people[user]?.script.paused ?? false
    }

    private func isBlockedBetween(_ a: UUID, _ b: UUID) -> Bool {
        blocks.contains(UserPair(blocker: a, blocked: b)) || blocks.contains(UserPair(blocker: b, blocked: a))
    }

    private func matchBetween(_ a: UUID, _ b: UUID) -> UUID? {
        let other = a == myID ? b : a
        return matches.values.first { $0.other == other }?.id
    }

    private func matchingReady(_ user: UUID) -> Bool {
        if user == myID {
            return profile?.isComplete == true && account.ageConfirmed && account.termsAcceptedVersion != nil
                && account.privacyAcceptedVersion != nil && preferences.isComplete
        }
        return people[user] != nil
    }

    private struct Prefs { let gender: MatchGender?; let showMe: Set<MatchGender>; let ages: ClosedRange<Int>; let verifiedOnly: Bool; let age: Int; let review: ReviewStatus }

    private func prefs(of user: UUID) -> Prefs? {
        if user == myID {
            guard let profile, preferences.ageMin <= preferences.ageMax else { return nil }
            return Prefs(gender: preferences.matchGender, showMe: preferences.showMe, ages: preferences.ageMin...preferences.ageMax,
                         verifiedOnly: account.verifiedOnlyDiscovery, age: profile.age, review: profile.photoReviewStatus)
        }
        guard let person = people[user] else { return nil }
        return Prefs(gender: person.script.matchGender, showMe: person.script.showMe, ages: person.script.ageRange,
                     verifiedOnly: person.script.verifiedOnly, age: person.profile.age, review: person.profile.photoReviewStatus)
    }

    /// `can_match(a, b)`: the single eligibility predicate used at discovery, interest and match creation.
    private func canMatch(_ a: UUID, _ b: UUID) -> Bool {
        guard a != b, matchingReady(a), matchingReady(b),
              let sa = activeSession(of: a), let sb = activeSession(of: b), sa.slug == sb.slug, sa.version == sb.version,
              let pa = prefs(of: a), let pb = prefs(of: b), let ga = pa.gender, let gb = pb.gender,
              pa.showMe.contains(gb), pb.showMe.contains(ga), pa.ages.contains(pb.age), pb.ages.contains(pa.age),
              pa.review != .rejected, pb.review != .rejected,
              !pa.verifiedOnly || pb.review == .approved, !pb.verifiedOnly || pa.review == .approved,
              !isPaused(a), !isPaused(b), !isBlockedBetween(a, b) else { return false }
        return true
    }

    private func requireSignedIn() throws {
        guard signedInEmail != nil else { throw CrushlyError.notAuthenticated }
    }

    /// Fixed-window counters, like `enforce_rate_limit`.
    private func enforceRateLimit(_ bucket: String, _ limits: [(max: Int, window: Int)]) throws {
        guard options.enforceRateLimits else { return }
        let t = now().timeIntervalSince1970
        for limit in limits {
            let start = Int(t / Double(limit.window)) * limit.window
            let key = "\(bucket):\(limit.window):\(start)"
            rateHits[key, default: 0] += 1
            if rateHits[key]! > limit.max { throw CrushlyError.rateLimited }
        }
    }

    /// `check_evidence`: plausibility only. The demo can't verify location any more than the server can.
    private func checkEvidence(_ e: LocationEvidence, in zone: SpaceZone?, previousFixMs: Int64?, allowStationary: Bool) throws -> Int64 {
        let ts = Int64((e.fixTimestamp.timeIntervalSince1970 * 1000).rounded())
        let age = Int64((e.fixAge * 1000).rounded())
        guard age >= 0, e.horizontalAccuracy > 0, e.horizontalAccuracy.isFinite else { throw CrushlyError.invalidInput("Bad evidence.") }
        if e.stationary && !allowStationary { throw CrushlyError.staleEvidence }
        let maxAccuracy = zone?.maxAccuracy(default: rules.evidenceMaxAccuracyMeters) ?? rules.evidenceMaxAccuracyMeters
        if e.horizontalAccuracy > maxAccuracy { throw CrushlyError.insufficientAccuracy }
        let maxAge = e.stationary ? rules.evidenceStationaryMaxFixAgeSeconds : rules.evidenceMaxFixAgeSeconds
        if Double(age) > maxAge * 1000 { throw CrushlyError.staleEvidence }
        if let previousFixMs, (!e.stationary && ts <= previousFixMs) || (e.stationary && ts < previousFixMs) {
            throw CrushlyError.staleEvidence
        }
        return ts
    }

    private func endMyParticipation() -> Int64 {
        consentEpoch += 1
        if let session = mySession { purgeSession(session.id) }
        mySession = nil
        return consentEpoch
    }

    private func createMatch(with other: UUID) {
        guard matchBetween(myID, other) == nil else { return }
        let match = DemoMatch(id: UUID(), other: other, createdAt: now())
        matches[match.id] = match
        poke(.match, match.id)
    }

    private func deleteMatch(_ id: UUID) {
        guard matches.removeValue(forKey: id) != nil else { return }
        messages[id] = nil
        deletedMatchIDs.insert(id)
        poke(.conversationRemoved, id)
    }

    /// Mirrors the realtime triggers: content-free pokes only.
    private func poke(_ kind: RealtimePoke.Kind, _ matchID: UUID) {
        pokeContinuation?.yield(RealtimePoke(kind: kind, matchID: matchID))
    }

    private func nextMessageTime(in matchID: UUID) -> Date {
        let last = messages[matchID]?.last?.createdAt ?? .distantPast
        return max(now(), last.addingTimeInterval(0.001))
    }

    private func appendMessage(_ message: DemoMessage, to matchID: UUID) {
        messages[matchID, default: []].append(message)
        poke(.message, matchID)
    }

    /// Demo only: lets scripted replies arrive without the user doing anything (the live app gets a poke).
    func runScriptsNow() { runDueScripts() }

    // MARK: AuthService

    func restoreSession() async -> String? { signedInEmail }

    /// The demo keeps no accounts between runs, so "sign in" accepts any USC address like "create account".
    func requestCode(email: String, createAccount: Bool) async throws {
        try await pause()
        guard rules.isAllowedEmail(email) else { throw CrushlyError.domainNotAllowed }
        pendingCodeEmail = email.lowercased()
    }

    func verifyCode(email: String, code: String) async throws {
        try await pause()
        guard pendingCodeEmail == email.lowercased(), code == DemoWorld.demoCode else {
            throw CrushlyError.invalidVerificationCode
        }
        signedInEmail = email.lowercased()
    }

    func signOut() async throws {
        await stopPokes()
        signedInEmail = nil
    }

    func deleteAccount() async throws {
        try await pause()
        // Everything tied to this account goes. Fictional people's scripts no longer target it.
        profile = nil; account = PrivateAccount(); preferences = MatchPreferences(); prefs = NotificationPrefs()
        _ = endMyParticipation()
        matchingPaused = false; pausedUntil = nil
        photoStore = [:]; interests = []; exposures = []; blocks = []; blockedAt = [:]
        for id in matches.keys { deleteMatch(id) }
        scheduled = []; replyCursor = [:]
        signedInEmail = nil
    }

    // MARK: ProfileService

    func loadAccount() async throws -> AccountSnapshot {
        try await pause()
        try requireSignedIn()
        return AccountSnapshot(userID: myID, email: signedInEmail ?? "", profile: profile, account: account,
                               preferences: preferences, prefs: prefs, rules: rules, serverNow: now())
    }

    func saveProfile(_ draft: Profile) async throws -> Profile {
        try await pause()
        try requireSignedIn()
        var saved = draft
        saved.id = myID
        saved.firstName = String(draft.firstName.trimmingCharacters(in: .whitespaces).prefix(ProfileRules.firstNameMaxLength))
        saved.promptAnswer = String(draft.promptAnswer.prefix(ProfileRules.promptMaxLength))
        guard saved.age >= 18 else { throw CrushlyError.invalidInput("You must be 18 or older.") }
        guard saved.interests.count == ProfileRules.interestCount else {
            throw CrushlyError.invalidInput("Pick exactly \(ProfileRules.interestCount) interests.")
        }
        // Server-only fields cannot be changed by the client. Like profiles_guard: photos are live as soon as they're
        // saved, so a photo change makes the profile approved straight away.
        saved.photoReviewStatus = profile?.photoReviewStatus ?? .pending
        if profile?.photoPaths != saved.photoPaths { saved.photoReviewStatus = saved.photoPaths.isEmpty ? .pending : .approved }
        saved.selfieStatus = profile?.selfieStatus ?? .notStarted
        saved.universityDomain = "usc.edu"
        profile = saved
        return saved
    }

    func saveVerifiedOnlyDiscovery(_ enabled: Bool) async throws {
        try await pause()
        try requireSignedIn()
        account.verifiedOnlyDiscovery = enabled
    }

    func updateMatchPreferences(_ p: MatchPreferences) async throws {
        try await pause()
        try requireSignedIn()
        guard p.matchGender != nil, !p.showMe.isEmpty, p.ageMin >= 18, p.ageMax <= 120, p.ageMin <= p.ageMax else {
            throw CrushlyError.invalidInput("Please check your matching preferences.")
        }
        preferences = p
    }

    func acceptTerms(termsVersion: String, privacyVersion: String, ageConfirmed: Bool) async throws {
        try await pause()
        guard ageConfirmed else { throw CrushlyError.invalidInput("You must confirm you are 18 or older.") }
        account.termsAcceptedVersion = termsVersion
        account.privacyAcceptedVersion = privacyVersion
        account.ageConfirmed = true
    }

    func uploadPhoto(_ jpeg: Data) async throws -> String {
        try await pause()
        // Fault injection for tests and the demo controls (the real check runs on the device, in AppState).
        if simulateFlaggedPhotos > 0 {
            simulateFlaggedPhotos -= 1
            throw CrushlyError.photoRejected
        }
        let path = "demo/\(UUID().uuidString).jpg"
        photoStore[path] = jpeg
        return path
    }

    func deletePhoto(path: String) async throws {
        photoStore[path] = nil
    }

    func photoURL(for path: String) async -> URL? { nil }

    // MARK: SpaceService

    func zones() async throws -> [SpaceZone] {
        try await pause()
        try requireSignedIn()
        return zones.filter { $0.isUsable(allowDrafts: rules.allowDraftSpaces) }
    }

    // MARK: ParticipationService

    func myParticipation() async throws -> ParticipationStatus {
        try await pause()
        try requireSignedIn()
        return participationStatus()
    }

    private func participationStatus() -> ParticipationStatus {
        let paused = isPaused(myID)
        let session = mySession.flatMap { s in
            s.leaseExpiresAt > now()
                ? ParticipationSession(id: s.id, spaceSlug: s.slug, boundaryVersion: s.boundaryVersion,
                                       leaseExpiresAt: s.leaseExpiresAt, lastSeq: s.lastSeq)
                : nil
        }
        return ParticipationStatus(serverNow: now(), consentEpoch: consentEpoch, matchingPaused: paused,
                                   pausedUntil: paused ? pausedUntil : nil, session: session)
    }

    func openParticipation(spaceSlug: String, boundaryVersion: Int, consentEpoch epoch: Int64, clientRequestID: UUID,
                           evidence: LocationEvidence) async throws -> ParticipationLease {
        try await pause()
        try requireSignedIn()
        // Idempotent retry of the request that created the current, still-valid session.
        if let s = mySession, s.clientRequestID == clientRequestID, s.consentEpoch == epoch, s.leaseExpiresAt > now() {
            return ParticipationLease(sessionID: s.id, leaseExpiresAt: s.leaseExpiresAt, serverNow: now())
        }
        try enforceRateLimit("open", [(30, 3600)])
        if isPaused(myID) { throw CrushlyError.matchingPaused }
        if epoch != consentEpoch { throw CrushlyError.consentStale }
        if !matchingReady(myID) { throw CrushlyError.profileIncomplete }
        guard let zone = zones.first(where: { $0.slug == spaceSlug && $0.isUsable(allowDrafts: rules.allowDraftSpaces) }) else {
            throw CrushlyError.spaceUnavailable
        }
        if zone.boundaryVersion != boundaryVersion { throw CrushlyError.boundaryOutdated }
        let fix = try checkEvidence(evidence, in: zone, previousFixMs: nil, allowStationary: false)

        // Never transfer consent: whatever existed before ends now, interests included.
        if let old = mySession { purgeSession(old.id) }
        let session = MySession(id: UUID(), slug: zone.slug, boundaryVersion: zone.boundaryVersion, consentEpoch: consentEpoch,
                                clientRequestID: clientRequestID,
                                leaseExpiresAt: now().addingTimeInterval(TimeInterval(rules.participationLeaseSeconds)),
                                lastSeq: 0, lastFixMs: fix, interestsSent: 0)
        mySession = session

        for person in people.values {
            let id = person.profile.id
            if let after = person.script.interestedAfter {
                schedule(after: after) { [weak self] in self?.scriptedInterest(from: id) }
            }
            if let after = person.script.leavesAfter, !departureScheduled {
                schedule(after: after) { [weak self] in self?.personLeaves(id) }
            }
        }
        departureScheduled = true
        runDueScripts()
        return ParticipationLease(sessionID: session.id, leaseExpiresAt: session.leaseExpiresAt, serverNow: now())
    }

    func renewParticipation(sessionID: UUID, seq: Int64, evidence: LocationEvidence) async throws -> ParticipationLease {
        try await pause()
        try requireSignedIn()
        try enforceRateLimit("renew", [(12, 60)])
        guard var s = mySession, s.id == sessionID, s.leaseExpiresAt > now() else { throw CrushlyError.sessionExpired }
        if isPaused(myID) { throw CrushlyError.matchingPaused }
        if seq <= s.lastSeq { throw CrushlyError.staleRequest }
        let fix = try checkEvidence(evidence, in: zones.first { $0.slug == s.slug }, previousFixMs: s.lastFixMs, allowStationary: true)
        s.leaseExpiresAt = now().addingTimeInterval(TimeInterval(rules.participationLeaseSeconds))
        s.lastSeq = seq
        s.lastFixMs = fix
        mySession = s
        return ParticipationLease(sessionID: s.id, leaseExpiresAt: s.leaseExpiresAt, serverNow: now())
    }

    @discardableResult
    func revokeParticipation() async throws -> Int64 {
        try await pause()
        try requireSignedIn()
        return endMyParticipation()
    }

    func setMatchingPaused(_ paused: Bool, minutes: Int?) async throws -> ParticipationStatus {
        try await pause()
        try requireSignedIn()
        if paused, let minutes, !rules.pauseDurationsMinutes.contains(minutes) { throw CrushlyError.invalidDuration }
        if paused {
            _ = endMyParticipation()
            matchingPaused = true
            pausedUntil = minutes.map { now().addingTimeInterval(TimeInterval($0) * 60) }
        } else {
            // Resuming never opens a session; the user must be in a space and consent again.
            matchingPaused = false
            pausedUntil = nil
        }
        return participationStatus()
    }

    // MARK: DiscoveryService

    func discoverCandidates() async throws -> DiscoveryResult {
        try await pause()
        try requireSignedIn()
        guard let me = activeSession(of: myID) else { throw CrushlyError.notParticipating }
        try enforceRateLimit("discover", [(1, 15), (60, 3600)])
        let others = people.keys.filter { activeSession(of: $0).map { $0.slug == me.slug && $0.version == me.version } ?? false }
        if others.count + 1 < rules.discoveryMinParticipants { return .quiet }   // never an exact count
        let picked = others
            .filter { matchBetween(myID, $0) == nil && canMatch(myID, $0) }
            .shuffled()                                                       // no stable order to diff
            .prefix(rules.discoveryMaxResults)
        for id in picked { if let theirs = activeSession(of: id) { exposures.insert(SessionPair(viewer: me.id, target: theirs.id)) } }
        return .candidates(picked.compactMap { people[$0]?.profile })
    }

    func expressInterest(in target: UUID) async throws -> InterestResult {
        try await pause()
        try requireSignedIn()
        guard target != myID else { throw CrushlyError.invalidInput("You can't do that.") }
        try enforceRateLimit("interest", [(30, 3600)])
        guard var me = mySession, me.leaseExpiresAt > now() else { throw CrushlyError.notParticipating }
        guard let them = activeSession(of: target), canMatch(myID, target),
              exposures.contains(SessionPair(viewer: me.id, target: them.id)) else { throw CrushlyError.notAvailable }
        if matchBetween(myID, target) != nil { throw CrushlyError.alreadyMatched }
        if interests.contains(where: { $0.sender == me.id && $0.recipient == them.id }) { throw CrushlyError.alreadySent }
        if me.interestsSent >= rules.interestsPerSession { throw CrushlyError.limitReached }

        me.interestsSent += 1
        mySession = me
        let remaining = rules.interestsPerSession - me.interestsSent
        if let reciprocal = interests.firstIndex(where: { $0.sender == them.id && $0.recipient == me.id }) {
            interests.remove(at: reciprocal)
            createMatch(with: target)
            return .matched(matchID: matchBetween(myID, target)!, remaining: remaining)
        }
        interests.append(Interest(sender: me.id, recipient: them.id, visibleAt: now().addingTimeInterval(options.receiptDelay)))
        if let reply = people[target]?.script.replyAfter {
            schedule(after: reply) { [weak self] in self?.scriptedInterest(from: target) }
        }
        return .sent(remaining: remaining)
    }

    func interestReceipts() async throws -> Int {
        try await pause()
        try requireSignedIn()
        guard let me = activeSession(of: myID) else { return 0 }
        return interests.filter { interest in
            guard interest.recipient == me.id, interest.visibleAt <= now(), let sender = owner(ofSession: interest.sender),
                  activeSession(of: sender) != nil else { return false }
            return !isBlockedBetween(myID, sender)
        }.count
    }

    func sentInterests() async throws -> Set<UUID> {
        try await pause()
        try requireSignedIn()
        guard let me = activeSession(of: myID) else { return [] }
        return Set(interests.filter { $0.sender == me.id }.compactMap { owner(ofSession: $0.recipient) })
    }

    // MARK: ConversationService

    func conversations() async throws -> [Conversation] {
        try await pause()
        try requireSignedIn()
        return matches.values
            .filter { !isBlockedBetween(myID, $0.other) }
            .compactMap { match -> Conversation? in
                guard let other = people[match.other]?.profile else { return nil }
                let last = messages[match.id]?.last(where: { !$0.deleted })
                let unread = last.map { $0.senderID != myID && $0.createdAt > (match.myLastReadAt ?? .distantPast) } ?? false
                return Conversation(id: match.id, createdAt: match.createdAt, other: other, lastMessageAt: last?.createdAt,
                                    lastMessagePreview: last.flatMap { $0.kind == .text ? String($0.body.prefix(80)) : nil },
                                    lastMessageFromMe: last.map { $0.senderID == myID }, unread: unread,
                                    lastMessageKind: last?.kind)
            }
            .sorted { ($0.lastMessageAt ?? $0.createdAt) > ($1.lastMessageAt ?? $1.createdAt) }
    }

    private func requireParticipant(_ matchID: UUID) throws -> DemoMatch {
        guard let match = matches[matchID], !isBlockedBetween(myID, match.other) else { throw CrushlyError.notFound }
        return match
    }

    func fetchMessages(matchID: UUID, before: MessageCursor?, limit: Int) async throws -> [ChatMessage] {
        try await pause()
        try requireSignedIn()
        _ = try requireParticipant(matchID)
        func key(_ date: Date, _ id: UUID) -> (Date, String) { (date, id.uuidString.lowercased()) }
        return (messages[matchID] ?? [])
            .sorted { key($0.createdAt, $0.id) > key($1.createdAt, $1.id) }
            .filter { m in before.map { key(m.createdAt, m.id) < key($0.createdAt, $0.id) } ?? true }
            .prefix(max(1, min(limit, 50)))
            .map { chatMessage($0, in: matchID) }
    }

    private func chatMessage(_ m: DemoMessage, in matchID: UUID) -> ChatMessage {
        let quoted = m.replyToID.flatMap { id in messages[matchID]?.first { $0.id == id } }
        return ChatMessage(
            id: m.id, senderIsMe: m.senderID == myID, body: m.body, createdAt: m.createdAt, kind: m.kind, isDeleted: m.deleted,
            replyTo: quoted.map { ReplyPreview(id: $0.id, body: $0.deleted ? "" : String($0.body.prefix(140)),
                                               senderIsMe: $0.senderID == myID, isDeleted: $0.deleted) },
            reactions: m.reactionOrder.compactMap { user in m.reactions[user].map { MessageReaction(emoji: $0, fromMe: user == myID) } })
    }

    private func messageIndex(_ messageID: UUID) throws -> (match: UUID, index: Int) {
        for (match, list) in messages {
            if let index = list.firstIndex(where: { $0.id == messageID }) {
                _ = try requireParticipant(match)
                return (match, index)
            }
        }
        throw CrushlyError.notFound
    }

    func react(messageID: UUID, emoji: String?) async throws {
        try await pause()
        try requireSignedIn()
        let (match, index) = try messageIndex(messageID)
        guard let message = messages[match]?[index], message.kind == .text, !message.deleted else {
            throw CrushlyError.invalidInput("Please check what you entered.")
        }
        let value = emoji?.trimmingCharacters(in: .whitespaces)
        if let value, !value.isEmpty,
           value.unicodeScalars.count > 16
            || value.unicodeScalars.contains(where: { ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0)))
                                                      || $0.properties.isWhitespace || $0 == "<" || $0 == ">" }) {
            throw CrushlyError.invalidInput("Please check what you entered.")
        }
        try enforceRateLimit("reaction", [(60, 60), (1000, 86400)])
        if let value, !value.isEmpty {
            messages[match]?[index].reactions[myID] = value
            messages[match]?[index].reactionOrder.removeAll { $0 == myID }
            messages[match]?[index].reactionOrder.append(myID)
        } else {
            messages[match]?[index].reactions[myID] = nil
            messages[match]?[index].reactionOrder.removeAll { $0 == myID }
        }
        poke(.message, match)
    }

    func unsendMessage(messageID: UUID) async throws {
        try await pause()
        try requireSignedIn()
        let (match, index) = try messageIndex(messageID)
        guard let message = messages[match]?[index], message.senderID == myID else { throw CrushlyError.notFound }
        guard message.kind == .text else { throw CrushlyError.invalidInput("Please check what you entered.") }
        if message.deleted { return }
        try enforceRateLimit("unsend", [(30, 60), (300, 86400)])
        messages[match]?[index].deleted = true
        messages[match]?[index].body = ""
        messages[match]?[index].reactions = [:]
        messages[match]?[index].reactionOrder = []
        poke(.message, match)
    }

    func recordScreenshot(matchID: UUID) async throws -> SentMessageReceipt {
        try await pause()
        try requireSignedIn()
        _ = try requireParticipant(matchID)
        if let recent = messages[matchID]?.last(where: { $0.senderID == myID && $0.kind == .screenshot }),
           now().timeIntervalSince(recent.createdAt) < 10 {
            return SentMessageReceipt(id: recent.id, createdAt: recent.createdAt)
        }
        try enforceRateLimit("screenshot", [(6, 60), (100, 86400)])
        let message = DemoMessage(id: UUID(), senderID: myID, body: "", createdAt: nextMessageTime(in: matchID), kind: .screenshot)
        appendMessage(message, to: matchID)
        return SentMessageReceipt(id: message.id, createdAt: message.createdAt)
    }

    func sendMessage(matchID: UUID, clientMessageID: UUID, body: String, replyToID: UUID?) async throws -> SentMessageReceipt {
        try await pause()
        if simulateOfflineSends > 0 { simulateOfflineSends -= 1; throw URLError(.notConnectedToInternet) }
        try requireSignedIn()
        _ = try requireParticipant(matchID)
        // Retry of a message that already landed: return it, never insert twice.
        for (match, list) in messages {
            if let existing = list.first(where: { $0.id == clientMessageID }) {
                guard existing.senderID == myID, match == matchID else { throw CrushlyError.invalidInput("Please try again.") }
                return SentMessageReceipt(id: existing.id, createdAt: existing.createdAt)
            }
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= rules.messageMaxChars else { throw CrushlyError.invalidInput("Messages must be 1–\(rules.messageMaxChars) characters.") }
        if let replyToID, !(messages[matchID] ?? []).contains(where: { $0.id == replyToID && $0.kind == .text && !$0.deleted }) {
            throw CrushlyError.invalidInput("That message can't be replied to.")
        }
        try enforceRateLimit("message", [(20, 60), (500, 86400)])
        let message = DemoMessage(id: clientMessageID, senderID: myID, body: trimmed, createdAt: nextMessageTime(in: matchID),
                                  replyToID: replyToID)
        appendMessage(message, to: matchID)
        schedule(after: options.replyDelay) { [weak self] in self?.scriptedReply(in: matchID) }
        if simulateLostResponses > 0 { simulateLostResponses -= 1; throw URLError(.timedOut) }
        return SentMessageReceipt(id: message.id, createdAt: message.createdAt)
    }

    func markConversationRead(matchID: UUID) async throws {
        try await pause()
        try requireSignedIn()
        _ = try requireParticipant(matchID)
        matches[matchID]?.myLastReadAt = now()
    }

    func leaveConversation(matchID: UUID) async throws {
        try await pause()
        try requireSignedIn()
        guard matches[matchID] != nil else { throw CrushlyError.notFound }
        deleteMatch(matchID)
    }

    // MARK: SafetyService

    func block(userID: UUID) async throws {
        try await pause()
        try requireSignedIn()
        try blockNow(userID)
    }

    private func blockNow(_ target: UUID) throws {
        guard target != myID else { throw CrushlyError.invalidInput("You can't do that.") }
        guard people[target] != nil else { throw CrushlyError.notFound }
        blocks.insert(UserPair(blocker: myID, blocked: target))
        blockedAt[target] = now()
        if let match = matchBetween(myID, target) { deleteMatch(match) }
        if let mine = activeSession(of: myID)?.id, let theirs = activeSession(of: target)?.id {
            interests.removeAll { ($0.sender == mine && $0.recipient == theirs) || ($0.sender == theirs && $0.recipient == mine) }
        }
    }

    func unblock(userID: UUID) async throws {
        try await pause()
        blocks.remove(UserPair(blocker: myID, blocked: userID))
        blockedAt[userID] = nil
    }

    func blockedUsers() async throws -> [BlockedUser] {
        try await pause()
        return blocks.filter { $0.blocker == myID }.compactMap { pair in
            people[pair.blocked].map { BlockedUser(id: pair.blocked, firstName: $0.profile.firstName, blockedAt: blockedAt[pair.blocked] ?? now()) }
        }.sorted { $0.blockedAt > $1.blockedAt }
    }

    func report(userID: UUID, category: ReportCategory, details: String, evidenceMessageIDs: [UUID]) async throws {
        try await pause()
        try requireSignedIn()
        guard userID != myID, details.count <= 2000, evidenceMessageIDs.count <= 50 else { throw CrushlyError.invalidInput("Please check your report.") }
        guard people[userID] != nil else { throw CrushlyError.notFound }
        try enforceRateLimit("report", [(10, 86400)])
        var evidence: [DemoMessage] = []
        if !evidenceMessageIDs.isEmpty {
            // Only messages from the conversation with this person, and only those the reporter selected.
            let wanted = Set(evidenceMessageIDs)
            guard let match = matchBetween(myID, userID) else { throw CrushlyError.invalidInput("Please check your report.") }
            evidence = (messages[match] ?? []).filter { wanted.contains($0.id) && $0.kind == .text && !$0.deleted }
            guard evidence.count == wanted.count else { throw CrushlyError.invalidInput("Please check your report.") }
        }
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        submittedReports.append(DemoReport(target: userID, category: category, details: trimmed.isEmpty ? nil : trimmed, evidence: evidence))
        try blockNow(userID)   // reporting also blocks and ends the conversation
    }

    // MARK: NotificationService / AnalyticsService

    func updatePrefs(_ newPrefs: NotificationPrefs) async throws {
        try await pause()
        prefs = newPrefs
    }

    func registerDevice(token: String, sandbox: Bool) async throws {}
    func unregisterDevice(token: String) async throws {}

    // MARK: RealtimeService

    func startPokes(userID: UUID) async -> AsyncStream<RealtimePoke> {
        pokeContinuation?.finish()
        let (stream, continuation) = AsyncStream<RealtimePoke>.makeStream(bufferingPolicy: .bufferingNewest(16))
        pokeContinuation = continuation
        return stream
    }

    func stopPokes() async {
        pokeContinuation?.finish()
        pokeContinuation = nil
    }

    func track(_ event: AnalyticsEvent) async {}
}
