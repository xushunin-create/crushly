import Foundation
import UIKit

/// In-memory backend for demo mode. Implements the same contracts as the live backend and enforces the
/// same rules as the SQL functions (docs/BACKEND_CONTRACT.md §3–4). All people are fictional.
/// Nothing here is persisted or sent anywhere; relaunching resets the world.
final class DemoBackend: CrushlyBackend {
    struct Options: Equatable {
        /// Start already signed in with a finished profile (skips onboarding).
        var seededAccount = false
        /// Receipt visibility delay. The server uses 2–10 min; demo defaults to a few seconds so it is testable.
        var receiptDelay: TimeInterval = 3
        var latency: Duration = .milliseconds(180)
    }

    // MARK: State

    private(set) var options: Options
    let rules = AppRules.default
    private let startedAt: Date
    /// Demo-only clock offset so expiry can be tested without waiting ("Skip ahead" in Me › Demo).
    private(set) var clockOffset: TimeInterval = 0
    func now() -> Date { Date().addingTimeInterval(clockOffset) }

    private let myID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    private var signedInEmail: String?
    private var pendingCodeEmail: String?
    private var profile: Profile?
    private var account = PrivateAccount()
    private var prefs = NotificationPrefs()
    private var session: PulseSession?
    private var shield: ShieldState?
    private var photoStore: [String: Data] = [:]

    private var people: [UUID: DemoWorld.Person] = [:]
    private var spaces: [CampusSpace]
    private var signals: [DemoSignal] = []
    private var matchesByID: [UUID: DemoMatch] = [:]
    /// (blocker, blocked)
    private var blocks: Set<Pair> = []
    private var blockedAt: [UUID: Date] = [:]
    private var encounters: [UUID: Date] = [:]
    private var reports: [(UUID, ReportCategory, String)] = []
    private var scheduled: [(at: Date, run: () -> Void)] = []

    private struct Pair: Hashable { let a: UUID; let b: UUID }

    private struct DemoSignal {
        let id = UUID()
        let sender: UUID
        let recipient: UUID
        let spaceID: UUID?
        let createdAt: Date
        let expiresAt: Date
        let visibleAt: Date
        let spaceDisclosable: Bool
        var status: SignalStatus = .pending
        var matchID: UUID?
    }

    private struct DemoMatch {
        let id: UUID
        let other: UUID
        let kind: MatchKind
        let spaceID: UUID?
        let createdAt: Date
        var connection: Connection
        var actions: [ConnectionAction] = []
        var find: FindRequest?
    }

    init(options: Options = Options()) {
        self.options = options
        let start = Date()
        startedAt = start
        spaces = DemoWorld.spaces(now: start)
        for person in DemoWorld.people() { people[person.profile.id] = person }
        for person in people.values {
            if let after = person.script.signalsYouAfter {
                schedule(at: start.addingTimeInterval(after)) { [weak self] in self?.scriptedSignal(from: person.profile.id) }
            }
        }
        if options.seededAccount { seedAccount() }
    }

    private func seedAccount() {
        signedInEmail = "tommy@usc.edu"
        account = PrivateAccount(instagramHandle: "@tommy.trojan", termsAcceptedVersion: LegalDocuments.termsVersion,
                                 privacyAcceptedVersion: LegalDocuments.privacyVersion, ageConfirmed: true)
        profile = Profile(
            id: myID, firstName: "Tommy", age: 21, pronouns: "he/him", gender: "Man",
            interests: ["Music", "Design", "Coffee"], vibeTags: ["Night owl", "Deep talks"],
            promptQuestion: ProfilePrompts.all[1], promptAnswer: "The Village fountain with an iced latte.",
            intention: .figuringItOut, availability: .either, photoPaths: ["avatar:heart.fill|pink"],
            photoReviewStatus: .pending
        )
    }

    private func pause() async throws {
        try await Task.sleep(for: options.latency)
        runDueScripts()
    }

    // MARK: Demo controls (not part of the service contracts)

    func skipAhead(minutes: Double) {
        clockOffset += minutes * 60
        runDueScripts()
    }

    /// Demo-only: simulates the photo moderation decision that a reviewer would make in production.
    func simulatePhotoReview(_ status: ReviewStatus) {
        profile?.photoReviewStatus = status
    }

    var scenarioNotes: [(name: String, note: String)] {
        people.values.sorted { $0.profile.id.uuidString < $1.profile.id.uuidString }
            .map { ($0.profile.firstName, $0.script.note) }
    }

    // MARK: Scripted behaviour

    private func schedule(at date: Date, _ run: @escaping () -> Void) {
        scheduled.append((date, run))
    }

    private func runDueScripts() {
        let current = now()
        let due = scheduled.filter { $0.at <= current }
        scheduled.removeAll { $0.at <= current }
        due.forEach { $0.run() }
        expireLifecycle()
    }

    private func scriptedSignal(from sender: UUID) {
        guard !isBlockedBetween(sender, myID), !isShielded(myID) else { return }
        guard !signals.contains(where: { $0.sender == sender && $0.recipient == myID && $0.status == .pending }) else { return }
        _ = insertSignal(sender: sender, recipient: myID)
    }

    // MARK: Rules (mirror of the SQL predicates)

    private func liveSession(of user: UUID, at date: Date) -> (spaceID: UUID, paused: Bool)? {
        if user == myID {
            guard let session, session.state(at: date) == .live else { return nil }
            return (session.spaceID, false)
        }
        guard let person = people[user], let space = person.script.spaceID, let minutes = person.script.sessionMinutes,
              !person.script.paused else { return nil }
        guard startedAt.addingTimeInterval(minutes * 60) > date else { return nil }
        return (space, false)
    }

    private func isShielded(_ user: UUID) -> Bool {
        if user == myID { return shield?.isActive(at: now()) ?? false }
        return people[user]?.script.shielded ?? false
    }

    private func isBlockedBetween(_ a: UUID, _ b: UUID) -> Bool {
        blocks.contains(Pair(a: a, b: b)) || blocks.contains(Pair(a: b, b: a))
    }

    private func reviewStatus(_ user: UUID) -> ReviewStatus {
        user == myID ? (profile?.photoReviewStatus ?? .pending) : (people[user]?.profile.photoReviewStatus ?? .pending)
    }

    private func isDiscoverableToMe(_ target: UUID) -> Bool {
        let date = now()
        guard target != myID, profile?.isComplete == true,
              let mine = liveSession(of: myID, at: date), let theirs = liveSession(of: target, at: date),
              mine.spaceID == theirs.spaceID,
              !isShielded(myID), !isShielded(target), !isBlockedBetween(myID, target),
              reviewStatus(target) != .rejected else { return false }
        if people[target]?.script.verifiedOnly == true, reviewStatus(myID) != .approved { return false }
        if account.verifiedOnlyDiscovery, reviewStatus(target) != .approved { return false }
        return true
    }

    private func encounteredRecently(_ target: UUID) -> Bool {
        guard let seen = encounters[target] else { return false }
        return now().timeIntervalSince(seen) < Double(rules.encounterWindowHours) * 3600
    }

    private func crowd(in space: UUID) -> Int {
        let date = now()
        let others = people.keys.filter { liveSession(of: $0, at: date)?.spaceID == space && !isShielded($0) }.count
        return others + (liveSession(of: myID, at: date)?.spaceID == space ? 1 : 0)
    }

    @discardableResult
    private func insertSignal(sender: UUID, recipient: UUID) -> SendSignalResult {
        let date = now()
        let senderSpace = liveSession(of: sender, at: date)?.spaceID
        let signal = DemoSignal(
            sender: sender, recipient: recipient, spaceID: senderSpace, createdAt: date,
            expiresAt: date.addingTimeInterval(Double(rules.signalValidityHours) * 3600),
            visibleAt: date.addingTimeInterval(options.receiptDelay),
            spaceDisclosable: senderSpace.map { crowd(in: $0) >= 5 } ?? false
        )
        signals.append(signal)
        if sender == myID { session?.signalsSent += 1 }
        let remaining = rules.signalsPerSession - (session?.signalsSent ?? 0)

        // Reciprocal pending signal → exactly one match.
        if let reciprocalIndex = signals.firstIndex(where: {
            $0.sender == recipient && $0.recipient == sender && $0.status == .pending && $0.expiresAt > date
        }) {
            let other = sender == myID ? recipient : sender
            if let existing = matchesByID.values.first(where: { $0.other == other }) {
                return .matched(matchID: existing.id, remaining: remaining)
            }
            let mine = liveSession(of: myID, at: date)
            let theirs = liveSession(of: other, at: date)
            let kind: MatchKind = (mine != nil && theirs != nil && mine?.spaceID == theirs?.spaceID) ? .heartSync : .crossedHearts
            let match = DemoMatch(
                id: UUID(), other: other, kind: kind, spaceID: mine?.spaceID ?? senderSpace, createdAt: date,
                connection: Connection(status: .pendingConfirmation,
                                       confirmBy: date.addingTimeInterval(Double(rules.connectionConfirmHours) * 3600))
            )
            matchesByID[match.id] = match
            scheduleAfterMatch(match.id, other: other)
            signals[reciprocalIndex].status = .matched
            signals[reciprocalIndex].matchID = match.id
            signals[signals.count - 1].status = .matched
            signals[signals.count - 1].matchID = match.id
            return .matched(matchID: match.id, remaining: remaining)
        }

        if sender == myID, let reply = people[recipient]?.script.replyAfter {
            schedule(at: date.addingTimeInterval(reply)) { [weak self] in self?.scriptedSignal(from: recipient) }
        }
        return .sent(remaining: remaining)
    }

    private func scheduleAfterMatch(_ matchID: UUID, other: UUID) {
        for (delay, action) in people[other]?.script.afterMatch ?? [] {
            schedule(at: now().addingTimeInterval(delay)) { [weak self] in
                guard let self, var match = self.matchesByID[matchID], !self.isBlockedBetween(self.myID, other),
                      [.pendingConfirmation, .metTonight, .findLater].contains(match.connection.status) else { return }
                let date = self.now()
                switch action {
                case .suggest(let kind, let detail):
                    guard !match.actions.contains(where: { $0.kind == kind && $0.status == .pending }) else { return }
                    match.actions.append(ConnectionAction(id: UUID(), actorID: other, kind: kind, detail: detail,
                                                          status: .pending, createdAt: date))
                case .requestFind(let point):
                    guard self.hasSession(self.myID, at: date), self.hasSession(other, at: date), !self.isShielded(self.myID),
                          match.find.map({ $0.status != .pending && $0.status != .accepted }) ?? true else { return }
                    match.find = FindRequest(id: UUID(), requesterID: other, status: .pending, meetingPoint: point,
                                             respondBy: date.addingTimeInterval(Double(self.rules.findRequestTimeoutMinutes) * 60))
                }
                self.matchesByID[matchID] = match
            }
        }
    }

    /// A paused or live (not ended, not expired) session — the server's condition for keeping a meet-up open.
    private func hasSession(_ user: UUID, at date: Date) -> Bool {
        if user == myID { return session.map { $0.endedAt == nil && $0.expiresAt > date } ?? false }
        guard let person = people[user], person.script.spaceID != nil, let minutes = person.script.sessionMinutes else { return false }
        return startedAt.addingTimeInterval(minutes * 60) > date
    }

    private func expireLifecycle() {
        let date = now()
        for index in signals.indices where signals[index].status == .pending && signals[index].expiresAt <= date {
            signals[index].status = .expired
        }
        for (id, var match) in matchesByID {
            switch match.connection.status {
            case .pendingConfirmation where match.connection.confirmBy <= date,
                 .metTonight where (match.connection.activeUntil ?? .distantFuture) <= date,
                 .findLater where (match.connection.activeUntil ?? .distantFuture) <= date:
                match.connection.status = .expired
            default: break
            }
            if var find = match.find, find.status == .pending, find.respondBy <= date {
                find.status = .timedOut
                match.find = find
            } else if var find = match.find, find.status == .accepted, (find.activeUntil ?? .distantFuture) <= date {
                find.status = .completed   // matches the server's tick
                match.find = find
            }
            // Either person leaving Pulse ends an open meet-up (server: crushly_tick / end_open_finds).
            if var find = match.find, find.status == .pending || find.status == .accepted,
               !hasSession(myID, at: date) || !hasSession(match.other, at: date) {
                find.status = .cancelled
                match.find = find
            }
            matchesByID[id] = match
        }
    }

    private func publicProfile(_ id: UUID) -> PublicProfile? {
        guard var profile = people[id]?.profile else { return nil }
        if let space = liveSession(of: id, at: now())?.spaceID {
            profile.spaceName = spaces.first { $0.id == space }?.name
        }
        return profile
    }

    private func requireSignedIn() throws {
        guard signedInEmail != nil else { throw CrushlyError.notAuthenticated }
    }

    // MARK: AuthService

    func restoreSession() async -> String? { signedInEmail }

    func requestCode(email: String) async throws {
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

    #if DEBUG
    func devSignIn(email: String) async throws {
        try await pause()
        guard rules.isAllowedEmail(email) else { throw CrushlyError.domainNotAllowed }
        signedInEmail = email.lowercased()
    }
    #endif

    func signOut() async throws {
        signedInEmail = nil
    }

    func deleteAccount() async throws {
        try await pause()
        // Remove everything tied to this account. Fictional people's scripts no longer target it.
        profile = nil; account = PrivateAccount(); prefs = NotificationPrefs(); session = nil; shield = nil
        photoStore = [:]; signals = []; matchesByID = [:]; blocks = []; blockedAt = [:]; encounters = [:]
        scheduled = []
        signedInEmail = nil
    }

    // MARK: ProfileService

    func loadAccount() async throws -> AccountSnapshot {
        try await pause()
        try requireSignedIn()
        if var current = session, current.state(at: now()) == .expired {
            current.endedAt = current.expiresAt
            session = current
        }
        if shield.map({ !$0.isActive(at: now()) }) == true { shield = nil }
        return AccountSnapshot(
            userID: myID, email: signedInEmail ?? "", profile: profile, account: account,
            pulse: session?.endedAt == nil ? session : nil, shield: shield, prefs: prefs, rules: rules, serverNow: now()
        )
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
        // Server-only fields cannot be changed by the client.
        saved.photoReviewStatus = profile?.photoReviewStatus ?? .pending
        if let old = profile, old.photoPaths != saved.photoPaths { saved.photoReviewStatus = .pending }
        saved.selfieStatus = profile?.selfieStatus ?? .notStarted
        saved.universityDomain = "usc.edu"
        profile = saved
        return saved
    }

    func savePrivate(instagramHandle: String, verifiedOnlyDiscovery: Bool) async throws {
        try await pause()
        account.instagramHandle = instagramHandle
        account.verifiedOnlyDiscovery = verifiedOnlyDiscovery
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
        let path = "demo/\(UUID().uuidString).jpg"
        photoStore[path] = jpeg
        return path
    }

    func deletePhoto(path: String) async throws {
        photoStore[path] = nil
    }

    func photoURL(for path: String) async -> URL? { nil }

    /// Demo-only: local image bytes for an uploaded demo photo.
    func demoPhotoData(for path: String) -> Data? { photoStore[path] }

    // MARK: SpaceService

    func spaces() async throws -> [CampusSpace] {
        try await pause()
        return spaces
    }

    func enterSpaceCode(_ code: String) async throws -> CampusSpace {
        try await pause()
        let normalized = code.uppercased().trimmingCharacters(in: .whitespaces)
        guard let id = DemoWorld.eventCodes[normalized], let space = spaces.first(where: { $0.id == id }) else {
            throw CrushlyError.invalidCode
        }
        return space
    }

    // MARK: PulseService

    func startPulse(spaceID: UUID, durationMinutes: Int?, untilEventEnd: Bool, availability: Availability) async throws -> PulseSession {
        try await pause()
        try requireSignedIn()
        guard profile?.isComplete == true else { throw CrushlyError.profileIncomplete }
        guard account.hasAcceptedCurrentTerms else { throw CrushlyError.termsRequired }
        guard !isShielded(myID) else { throw CrushlyError.shielded }
        guard let space = spaces.first(where: { $0.id == spaceID }) else { throw CrushlyError.notFound }
        let date = now()
        let expires: Date
        if untilEventEnd {
            guard let end = space.endsAt, end > date else { throw CrushlyError.invalidDuration }
            expires = end
        } else {
            guard let minutes = durationMinutes, rules.pulseDurationsMinutes.contains(minutes) else { throw CrushlyError.invalidDuration }
            expires = date.addingTimeInterval(Double(minutes) * 60)
        }
        session = PulseSession(id: UUID(), spaceID: spaceID, availability: availability, startedAt: date,
                               expiresAt: expires, pausedAt: nil, endedAt: nil, signalsSent: 0)
        profile?.availability = availability
        return session!
    }

    func pausePulse() async throws -> PulseSession {
        try await pause()
        guard var current = session, current.endedAt == nil else { throw CrushlyError.noLiveSession }
        guard current.state(at: now()) != .expired else { throw CrushlyError.sessionExpired }
        current.pausedAt = now()
        session = current
        return current
    }

    func resumePulse() async throws -> PulseSession {
        try await pause()
        guard var current = session, current.endedAt == nil else { throw CrushlyError.noLiveSession }
        guard current.expiresAt > now() else { throw CrushlyError.sessionExpired }
        current.pausedAt = nil
        session = current
        return current
    }

    func endPulse() async throws {
        try await pause()
        session?.endedAt = now()
        session = nil
        expireLifecycle()
    }

    func aroundProfiles() async throws -> [PublicProfile] {
        try await pause()
        guard liveSession(of: myID, at: now()) != nil else {
            if rules.requireOwnPulseToViewAround { throw CrushlyError.noLiveSession }
            return []
        }
        let visible = people.keys.filter(isDiscoverableToMe).sorted { $0.uuidString < $1.uuidString }
        let date = now()
        for id in visible { encounters[id] = date }
        return visible.compactMap(publicProfile)
    }

    func recentEncounters() async throws -> [PublicProfile] {
        try await pause()
        return encounters.keys
            .filter { encounteredRecently($0) && !isDiscoverableToMe($0) && !isBlockedBetween(myID, $0) }
            .filter { id in !matchesByID.values.contains { $0.other == id } }
            .sorted { (encounters[$0] ?? .distantPast) > (encounters[$1] ?? .distantPast) }
            .compactMap { id in
                var profile = people[id]?.profile
                profile?.spaceName = nil
                return profile
            }
    }

    // MARK: SignalService

    func sendHeartSignal(to recipient: UUID) async throws -> SendSignalResult {
        try await pause()
        let date = now()
        guard recipient != myID else { throw CrushlyError.selfSignal }
        guard let current = session, current.state(at: date) == .live else { throw CrushlyError.noLiveSession }
        guard profile?.isComplete == true else { throw CrushlyError.profileIncomplete }
        guard !isShielded(myID) else { throw CrushlyError.shielded }
        guard !isShielded(recipient), !isBlockedBetween(myID, recipient),
              isDiscoverableToMe(recipient) || encounteredRecently(recipient) else { throw CrushlyError.notAvailable }
        guard !matchesByID.values.contains(where: { $0.other == recipient }) else { throw CrushlyError.alreadyMatched }
        guard current.signalsSent < rules.signalsPerSession else { throw CrushlyError.limitReached }
        guard !signals.contains(where: { $0.sender == myID && $0.recipient == recipient && $0.status == .pending && $0.expiresAt > date }) else {
            throw CrushlyError.alreadySignaled
        }
        return insertSignal(sender: myID, recipient: recipient)
    }

    func receipts() async throws -> [SignalReceipt] {
        try await pause()
        let date = now()
        return signals
            .filter { $0.recipient == myID && $0.status == .pending && $0.visibleAt <= date && $0.expiresAt > date }
            .filter { !isBlockedBetween($0.sender, myID) }
            .sorted { $0.createdAt > $1.createdAt }
            .map { signal in
                // Same coarsening as the server: 15-minute buckets, space only when crowded. No sender.
                let bucket = Date(timeIntervalSince1970: (signal.createdAt.timeIntervalSince1970 / 900).rounded(.down) * 900)
                let space = signal.spaceDisclosable ? spaces.first { $0.id == signal.spaceID }?.name : nil
                return SignalReceipt(id: signal.id, receivedBucket: bucket, spaceName: space)
            }
    }

    func sentSignals() async throws -> [SentSignal] {
        try await pause()
        return signals.filter { $0.sender == myID }.sorted { $0.createdAt > $1.createdAt }.compactMap { signal in
            guard let recipient = people[signal.recipient]?.profile else { return nil }
            return SentSignal(id: signal.id, recipient: recipient, createdAt: signal.createdAt,
                              expiresAt: signal.expiresAt, status: signal.status)
        }
    }

    // MARK: MatchService

    func matches() async throws -> [Match] {
        try await pause()
        return matchesByID.values
            .filter { !isBlockedBetween(myID, $0.other) }
            .sorted { $0.createdAt > $1.createdAt }
            .compactMap { match in
                guard let other = people[match.other]?.profile else { return nil }
                return Match(id: match.id, kind: match.kind, createdAt: match.createdAt,
                             spaceName: spaces.first { $0.id == match.spaceID }?.name, other: other,
                             connection: match.connection, openFind: match.find, actions: match.actions)
            }
    }

    private func mutateMatch(_ id: UUID, _ change: (inout DemoMatch) throws -> Void) throws {
        guard var match = matchesByID[id], !isBlockedBetween(myID, match.other) else { throw CrushlyError.notFound }
        try change(&match)
        matchesByID[id] = match
    }

    private func touch(_ match: inout DemoMatch) {
        let date = now()
        match.connection.lastActivityAt = date
        if match.connection.status == .pendingConfirmation { match.connection.status = .findLater }
        if match.connection.confirmedAt == nil { match.connection.confirmedAt = date }
        match.connection.activeUntil = date.addingTimeInterval(Double(rules.connectionInactiveDays) * 86400)
    }

    func setConnectionStatus(matchID: UUID, status: ConnectionStatus) async throws {
        try await pause()
        try mutateMatch(matchID) { match in
            guard match.connection.status != .expired || status == .removed else { throw CrushlyError.requestExpired }
            switch status {
            case .metTonight, .findLater:
                touch(&match)
                match.connection.status = status
            case .removed:
                match.connection.status = .removed
                if var find = match.find, find.status == .pending || find.status == .accepted {
                    find.status = .cancelled
                    match.find = find
                }
            default: throw CrushlyError.notPermitted
            }
        }
    }

    func sendConnectionAction(matchID: UUID, kind: ConnectionActionKind, detail: String?) async throws {
        try await pause()
        var otherID: UUID?
        var actionID = UUID()
        try mutateMatch(matchID) { match in
            guard match.connection.status != .expired, match.connection.status != .removed else { throw CrushlyError.requestExpired }
            guard !match.actions.contains(where: { $0.kind == kind && $0.status == .pending }) else {
                throw CrushlyError.invalidInput("You already sent that. Waiting for a reply.")
            }
            let action = ConnectionAction(id: UUID(), actorID: myID, kind: kind, detail: detail, status: .pending, createdAt: now())
            actionID = action.id
            match.actions.append(action)
            touch(&match)
            otherID = match.other
        }
        if let other = otherID, let delay = people[other]?.script.acceptsAfter {
            schedule(at: now().addingTimeInterval(delay)) { [weak self] in
                guard let self, var match = self.matchesByID[matchID],
                      let index = match.actions.firstIndex(where: { $0.id == actionID && $0.status == .pending }) else { return }
                match.actions[index].status = .accepted
                self.matchesByID[matchID] = match
            }
        }
    }

    func respondConnectionAction(actionID: UUID, accept: Bool) async throws {
        try await pause()
        guard let (id, _) = matchesByID.first(where: { $0.value.actions.contains { $0.id == actionID } }) else { throw CrushlyError.notFound }
        try mutateMatch(id) { match in
            guard let index = match.actions.firstIndex(where: { $0.id == actionID }), match.actions[index].actorID != myID,
                  match.actions[index].status == .pending else { throw CrushlyError.notPermitted }
            match.actions[index].status = accept ? .accepted : .declined
            touch(&match)
        }
    }

    func instagramHandle(matchID: UUID) async throws -> String? {
        try await pause()
        guard let match = matchesByID[matchID], !isBlockedBetween(myID, match.other),
              match.actions.contains(where: { $0.kind == .instagramExchange && $0.status == .accepted }) else { return nil }
        return people[match.other]?.script.instagram
    }

    func requestFind(matchID: UUID, meetingPoint: String) async throws {
        try await pause()
        let date = now()
        guard liveSession(of: myID, at: date) != nil else { throw CrushlyError.noLiveSession }
        guard !isShielded(myID) else { throw CrushlyError.shielded }
        var otherID: UUID?
        var requestID = UUID()
        try mutateMatch(matchID) { match in
            guard liveSession(of: match.other, at: date) != nil, !isShielded(match.other) else { throw CrushlyError.notAvailable }
            guard match.find.map({ $0.status != .pending && $0.status != .accepted }) ?? true else {
                throw CrushlyError.invalidInput("There's already an open request.")
            }
            let request = FindRequest(id: UUID(), requesterID: myID, status: .pending, meetingPoint: meetingPoint,
                                      respondBy: date.addingTimeInterval(Double(rules.findRequestTimeoutMinutes) * 60))
            requestID = request.id
            match.find = request
            touch(&match)
            otherID = match.other
        }
        if let other = otherID, let delay = people[other]?.script.acceptsAfter {
            schedule(at: now().addingTimeInterval(delay)) { [weak self] in
                guard let self, var match = self.matchesByID[matchID], var find = match.find, find.id == requestID,
                      find.status == .pending, self.liveSession(of: other, at: self.now()) != nil,
                      self.liveSession(of: self.myID, at: self.now()) != nil else { return }
                find.status = .accepted
                find.activeUntil = self.now().addingTimeInterval(Double(self.rules.findActiveMinutes) * 60)
                match.find = find
                match.connection.status = .metTonight
                self.matchesByID[matchID] = match
            }
        }
    }

    func respondFind(requestID: UUID, accept: Bool) async throws {
        try await pause()
        guard let (id, _) = matchesByID.first(where: { $0.value.find?.id == requestID }) else { throw CrushlyError.notFound }
        try mutateMatch(id) { match in
            guard var find = match.find, find.requesterID != myID, find.status == .pending else { throw CrushlyError.notPermitted }
            guard find.respondBy > now() else { throw CrushlyError.requestExpired }
            find.status = accept ? .accepted : .declined
            if accept { find.activeUntil = now().addingTimeInterval(Double(rules.findActiveMinutes) * 60) }
            match.find = find
            touch(&match)
        }
    }

    func cancelFind(requestID: UUID) async throws {
        try await pause()
        guard let (id, _) = matchesByID.first(where: { $0.value.find?.id == requestID }) else { throw CrushlyError.notFound }
        try mutateMatch(id) { match in
            match.find?.status = .cancelled
        }
    }

    func completeFind(requestID: UUID) async throws {
        try await pause()
        guard let (id, _) = matchesByID.first(where: { $0.value.find?.id == requestID }) else { throw CrushlyError.notFound }
        try mutateMatch(id) { match in
            guard match.find?.status == .accepted else { throw CrushlyError.notPermitted }
            match.find?.status = .completed
            match.connection.status = .metTonight
            touch(&match)
        }
    }

    // MARK: SafetyService

    func enterShield(durationMinutes: Int?) async throws -> ShieldState {
        try await pause()
        let date = now()
        let state = ShieldState(startedAt: date, activeUntil: durationMinutes.map { date.addingTimeInterval(Double($0) * 60) })
        shield = state
        session?.endedAt = date
        session = nil
        for (id, var match) in matchesByID where match.find?.status == .pending || match.find?.status == .accepted {
            match.find?.status = .cancelled
            matchesByID[id] = match
        }
        return state
    }

    func exitShield() async throws {
        try await pause()
        shield = nil
        // Deliberately does not restart Pulse.
    }

    func block(userID: UUID) async throws {
        try await pause()
        blocks.insert(Pair(a: myID, b: userID))
        blockedAt[userID] = now()
        for index in signals.indices where signals[index].status == .pending
            && Set([signals[index].sender, signals[index].recipient]) == Set([myID, userID]) {
            signals[index].status = .withdrawn
        }
        for (id, var match) in matchesByID where match.other == userID {
            if match.find?.status == .pending || match.find?.status == .accepted { match.find?.status = .cancelled }
            matchesByID[id] = match
        }
    }

    func unblock(userID: UUID) async throws {
        try await pause()
        blocks.remove(Pair(a: myID, b: userID))
        blockedAt[userID] = nil
    }

    func blockedUsers() async throws -> [BlockedUser] {
        try await pause()
        return blocks.filter { $0.a == myID }.compactMap { pair in
            people[pair.b].map { BlockedUser(id: pair.b, firstName: $0.profile.firstName, blockedAt: blockedAt[pair.b] ?? now()) }
        }
    }

    func report(userID: UUID, category: ReportCategory, details: String) async throws {
        try await pause()
        reports.append((userID, category, details))
        try await block(userID: userID)
    }

    // MARK: NotificationService / AnalyticsService

    func updatePrefs(_ newPrefs: NotificationPrefs) async throws {
        try await pause()
        prefs = newPrefs
    }

    func registerDevice(token: String, sandbox: Bool) async throws {}

    func track(_ event: AnalyticsEvent) async {
        #if DEBUG
        print("[demo analytics] \(event.rawValue)")
        #endif
    }
}
