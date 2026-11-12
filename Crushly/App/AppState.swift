import Foundation
import Observation
import SwiftUI

/// Single source of truth for authentication, profile completion, visibility and social state.
/// Views read from here and call intent methods; only AppState talks to the backend.
@Observable
final class AppState {
    enum Phase: Equatable {
        case launching
        case signedOut
        case needsTerms
        case needsProfile
        case ready
    }

    enum Tab: Hashable { case around, signals, me }

    // MARK: Environment

    let config: AppConfig
    let backend: CrushlyBackend
    /// Non-nil only in demo mode, for demo controls.
    let demo: DemoBackend?
    let feedback = FeedbackService.shared

    // MARK: Session & account

    private(set) var phase: Phase = .launching
    private(set) var email = ""
    private(set) var userID: UUID?
    private(set) var profile: Profile?
    private(set) var account = PrivateAccount()
    private(set) var prefs = NotificationPrefs()
    private(set) var rules = AppRules.default
    /// server time − device time; keeps countdowns honest when the device clock is off.
    private(set) var clockSkew: TimeInterval = 0

    // MARK: Visibility

    private(set) var pulse: PulseSession?
    private(set) var shield: ShieldState?
    private(set) var spaces: [CampusSpace] = []

    // MARK: Social

    private(set) var around: [PublicProfile] = []
    private(set) var aroundLoaded = false
    private(set) var recent: [PublicProfile] = []
    private(set) var receipts: [SignalReceipt] = []
    private(set) var sentSignals: [SentSignal] = []
    private(set) var matches: [Match] = []
    private(set) var blocked: [BlockedUser] = []

    // MARK: UI coordination

    var selectedTab: Tab = .around
    /// Full-screen mutual match reveal. Bottom navigation is hidden while set.
    var revealMatch: Match?
    var errorMessage: String?
    private(set) var isOffline = false

    private var revealedMatchIDs: Set<UUID> {
        get { Set((UserDefaults.standard.stringArray(forKey: "crushly.revealed") ?? []).compactMap(UUID.init)) }
        set { UserDefaults.standard.set(newValue.map(\.uuidString), forKey: "crushly.revealed") }
    }

    /// Receipts set aside with "Not Right Now". Stored on this device only; the server is unaffected.
    private var dismissedReceiptIDs: Set<UUID> {
        get { Set((UserDefaults.standard.stringArray(forKey: "crushly.dismissedReceipts") ?? []).compactMap(UUID.init)) }
        set { UserDefaults.standard.set(newValue.map(\.uuidString), forKey: "crushly.dismissedReceipts") }
    }

    func dismissReceipts() {
        dismissedReceiptIDs.formUnion(receipts.map(\.id))
        receipts = []
        feedback.play(.tap)
    }

    func muteSignalAlerts(hours: Double) async {
        var newPrefs = prefs
        newPrefs.signalsMutedUntil = now().addingTimeInterval(hours * 3600)
        await updatePrefs(newPrefs)
    }

    private var pollTask: Task<Void, Never>?
    private var modalDepth = 0
    private var pendingReveal: Match?
    /// Incremented to ask every open sheet to close (observed by `.closesForReveal()`).
    private(set) var dismissModalsToken = 0
    private var expiryTask: Task<Void, Never>?
    /// Set when a session ran out on its own; cleared when the user starts a new one or dismisses it.
    var sessionExpiredNotice = false

    // MARK: Notifications & routing

    let push: PushManager
    private(set) var notificationPermission: PushManager.Permission = .notDetermined
    /// Navigation path of the Signals tab (connection ids), so notifications can open a connection.
    var signalsPath: [UUID] = []
    /// A notification tapped before sign-in finished; applied once the account is ready.
    private(set) var pendingRoute: NotificationRoute?
    private var registeredToken: (user: UUID, token: String)?

    /// Observable so the primer disappears immediately; persisted so it stays dismissed.
    private var notificationPrimerDismissed = UserDefaults.standard.bool(forKey: "crushly.notificationPrimerDismissed") {
        didSet { UserDefaults.standard.set(notificationPrimerDismissed, forKey: "crushly.notificationPrimerDismissed") }
    }

    /// Ask for notification permission at a meaningful moment: after the first Heart Signal, never on launch.
    var shouldOfferNotifications: Bool {
        phase == .ready && notificationPermission == .notDetermined && !notificationPrimerDismissed && !sentSignals.isEmpty
    }

    init(config: AppConfig, backend: CrushlyBackend, demo: DemoBackend?, push: PushManager = .shared) {
        self.config = config
        self.backend = backend
        self.demo = demo
        self.push = push
        push.onToken = { [weak self] _ in Task { await self?.registerDeviceIfNeeded() } }
        push.onRoute = { [weak self] route in self?.open(route) }
    }

    func enableNotifications() async {
        notificationPermission = await push.requestPermission()
        notificationPrimerDismissed = true
        syncPulseReminder()
    }

    func dismissNotificationPrimer() {
        notificationPrimerDismissed = true
    }

    func refreshNotificationPermission() async {
        notificationPermission = await push.refreshPermission()
    }

    /// Opens the screen a notification points to, deferring until the account is ready.
    func open(_ route: NotificationRoute) {
        guard phase == .ready else {
            pendingRoute = route
            return
        }
        pendingRoute = nil
        revealMatch = nil
        switch route {
        case .around:
            selectedTab = .around
        case .signals:
            selectedTab = .signals
            signalsPath = []
        case .match(let id):
            selectedTab = .signals
            signalsPath = [id]
            Task { await refreshSocial() }
        }
    }

    private func registerDeviceIfNeeded() async {
        guard phase == .ready, let user = userID, let token = push.deviceToken,
              registeredToken.map({ $0.user != user || $0.token != token }) ?? true else { return }
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = false
        #endif
        if (try? await backend.registerDevice(token: token, sandbox: sandbox)) != nil {
            registeredToken = (user, token)
        }
    }

    private func syncPulseReminder() {
        if let pulse, pulse.endedAt == nil, pulse.expiresAt > now() {
            push.schedulePulseReminder(expiresAt: pulse.expiresAt.addingTimeInterval(-clockSkew), enabled: prefs.pulseExpiry)
        } else {
            push.cancelPulseReminder()
        }
    }

    static func make(config: AppConfig = .load()) -> AppState {
        switch config.environment {
        case .demo:
            let seeded = ProcessInfo.processInfo.arguments.contains("-CrushlyDemoSeeded")
            let demo = DemoBackend(options: .init(seededAccount: seeded))
            return AppState(config: config, backend: demo, demo: demo)
        case .live(let url, let key):
            return AppState(config: config, backend: SupabaseBackend(url: url, anonKey: key), demo: nil)
        }
    }

    // MARK: Derived state

    func now() -> Date { Date().addingTimeInterval(clockSkew) }

    var pulseState: PulseSession.State? { pulse?.state(at: now()) }
    var isShielded: Bool { shield?.isActive(at: now()) ?? false }
    var currentSpace: CampusSpace? { pulse.flatMap { session in spaces.first { $0.id == session.spaceID } } }
    var signalsRemaining: Int { max(0, rules.signalsPerSession - (pulse?.signalsSent ?? 0)) }

    func hasPendingSignal(to id: UUID) -> Bool {
        sentSignals.contains { $0.recipient.id == id && $0.status == .pending && $0.expiresAt > now() }
    }

    func match(with id: UUID) -> Match? {
        matches.first { $0.other.id == id && $0.connection.status != .removed }
    }

    var activeMatches: [Match] {
        matches.filter { [.pendingConfirmation, .metTonight, .findLater].contains($0.connection.status) }
    }

    // MARK: Lifecycle

    func bootstrap() async {
        guard await backend.restoreSession() != nil else {
            phase = .signedOut
            return
        }
        await reloadAccount()
        // The scene's first .active event can arrive before bootstrap finishes, so start refreshing here too.
        if phase != .signedOut { startPolling() }
        await refreshNotificationPermission()
        if demo != nil, let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-CrushlyRoute"),
           index + 1 < ProcessInfo.processInfo.arguments.count,
           let route = NotificationRoute(ProcessInfo.processInfo.arguments[index + 1]) {
            open(route)   // demo/test hook that simulates tapping a notification
        }
    }

    /// Re-reads everything from the backend; called on launch, foreground, reconnect and after mutations.
    func reloadAccount() async {
        do {
            let snapshot = try await backend.loadAccount()
            apply(snapshot)
            isOffline = false
            if phase == .ready { await refreshSocial() }
        } catch CrushlyError.notAuthenticated {
            resetToSignedOut()
        } catch {
            handle(error)
        }
    }

    private func apply(_ snapshot: AccountSnapshot) {
        userID = snapshot.userID
        email = snapshot.email
        profile = snapshot.profile
        account = snapshot.account
        clockSkew = snapshot.serverNow.timeIntervalSinceNow
        // A session that disappeared (or came back expired) without the user ending it ran out of time.
        if let previous = pulse, previous.expiresAt <= now(),
           snapshot.pulse == nil || snapshot.pulse?.state(at: now()) == .expired {
            sessionExpiredNotice = true
        }
        pulse = snapshot.pulse
        shield = snapshot.shield
        prefs = snapshot.prefs
        rules = snapshot.rules
        scheduleExpiryCheck()
        syncPulseReminder()
        if !account.hasAcceptedCurrentTerms {
            phase = .needsTerms
        } else if profile?.isComplete != true {
            phase = .needsProfile
        } else {
            phase = .ready
            Task { await registerDeviceIfNeeded() }
            if let route = pendingRoute { open(route) }
        }
    }

    /// Re-reads server state the moment the session or shield should end, so visibility changes on time
    /// instead of on the next poll. The server remains the authority either way.
    private func scheduleExpiryCheck() {
        expiryTask?.cancel()
        let deadlines = [pulse?.endedAt == nil ? pulse?.expiresAt : nil, shield?.activeUntil].compactMap { $0 }
        guard let next = deadlines.filter({ $0 > now() }).min() else { return }
        let delay = next.timeIntervalSince(now()) + 0.5
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.around = []
            await self.reloadAccount()
        }
    }

    func sceneBecameActive() async {
        guard phase != .launching, phase != .signedOut else { return }
        await reloadAccount()
        startPolling()
    }

    func sceneWentBackground() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Light polling while foregrounded. Realtime subscriptions can replace this for live mode; receipts are
    /// deliberately coarse either way.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard let self, self.phase == .ready else { continue }
                await self.reconcileVisibility()
                await self.refreshSocial()
            }
        }
    }

    /// Server timestamps are the source of truth: when the local countdown says the session ended,
    /// re-read state rather than trusting the client.
    private func reconcileVisibility() async {
        if let state = pulseState, state == .expired {
            await reloadAccount()
        } else if let shield, !shield.isActive(at: now()) {
            await reloadAccount()
        }
    }

    func refreshSocial() async {
        guard phase == .ready else { return }
        do {
            if spaces.isEmpty { spaces = try await backend.spaces() }
            async let receiptsCall = backend.receipts()
            async let sentCall = backend.sentSignals()
            async let matchesCall = backend.matches()
            let (newReceipts, newSent, newMatches) = try await (receiptsCall, sentCall, matchesCall)
            let dismissed = dismissedReceiptIDs
            receipts = newReceipts.filter { !dismissed.contains($0.id) }
            sentSignals = newSent
            detectNewMatches(newMatches)
            matches = newMatches
            if pulseState == .live {
                around = try await backend.aroundProfiles()
            } else {
                around = []
            }
            aroundLoaded = true
            recent = try await backend.recentEncounters()
            isOffline = false
        } catch let error as URLError where error.code == .notConnectedToInternet {
            isOffline = true
        } catch CrushlyError.noLiveSession {
            around = []
            aroundLoaded = true
        } catch {
            handle(error)
        }
    }

    private func detectNewMatches(_ incoming: [Match]) {
        var seen = revealedMatchIDs
        if matches.isEmpty && seen.isEmpty && !incoming.isEmpty && revealMatch == nil {
            // First load on this device: don't replay old reveals.
            seen.formUnion(incoming.filter { now().timeIntervalSince($0.createdAt) > 600 }.map(\.id))
        }
        if revealMatch == nil, let fresh = incoming.first(where: { !seen.contains($0.id) && $0.connection.status != .removed }) {
            seen.insert(fresh.id)
            present(fresh)
        }
        revealedMatchIDs = seen
    }

    /// iOS can't show the full-screen reveal on top of an open sheet, so open sheets are asked to close
    /// first and the reveal follows once the last one has gone.
    private func present(_ match: Match) {
        if modalDepth > 0 {
            pendingReveal = match
            dismissModalsToken += 1
        } else {
            show(match)
        }
    }

    private func show(_ match: Match) {
        revealMatch = match
        feedback.play(.heartSync)
        Task { await backend.track(.matchViewed) }
    }

    func modalAppeared() { modalDepth += 1 }

    func modalDisappeared() {
        modalDepth = max(0, modalDepth - 1)
        guard modalDepth == 0, let match = pendingReveal else { return }
        pendingReveal = nil
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            show(match)
        }
    }

    // MARK: Errors

    func handle(_ error: Error) {
        if let urlError = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(urlError.code) {
            isOffline = true
            errorMessage = CrushlyError.network.errorDescription
            return
        }
        if case CrushlyError.notAuthenticated = error {
            resetToSignedOut()
            return
        }
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        feedback.play(.warning)
    }

    /// Runs an intent, reporting failures through the shared banner. Returns false on failure.
    @discardableResult
    func perform(_ work: () async throws -> Void) async -> Bool {
        do {
            try await work()
            return true
        } catch {
            handle(error)
            return false
        }
    }

    private func resetToSignedOut() {
        pollTask?.cancel()
        pollTask = nil
        phase = .signedOut
        email = ""; userID = nil; profile = nil; account = PrivateAccount(); pulse = nil; shield = nil
        around = []; recent = []; receipts = []; sentSignals = []; matches = []; blocked = []; revealMatch = nil
        selectedTab = .around
        signalsPath = []
        registeredToken = nil
        push.cancelPulseReminder()
    }

    // MARK: Auth intents

    func requestCode(email: String) async throws {
        guard rules.isAllowedEmail(email) else { throw CrushlyError.domainNotAllowed }
        try await backend.requestCode(email: email.lowercased().trimmingCharacters(in: .whitespaces))
    }

    func verifyCode(email: String, code: String) async throws {
        try await backend.verifyCode(email: email.lowercased().trimmingCharacters(in: .whitespaces),
                                     code: code.trimmingCharacters(in: .whitespaces))
        await reloadAccount()
        startPolling()
    }

    #if DEBUG
    /// DEV ONLY — skips email code verification. Remove before launch.
    func devSignIn(email: String) async throws {
        guard rules.isAllowedEmail(email) else { throw CrushlyError.domainNotAllowed }
        try await backend.devSignIn(email: email.lowercased().trimmingCharacters(in: .whitespaces))
        await reloadAccount()
        startPolling()
    }
    #endif

    func acceptTerms() async throws {
        try await backend.acceptTerms(termsVersion: LegalDocuments.termsVersion,
                                      privacyVersion: LegalDocuments.privacyVersion, ageConfirmed: true)
        await reloadAccount()
    }

    func saveProfile(_ draft: Profile) async throws {
        let wasComplete = profile?.isComplete == true
        profile = try await backend.saveProfile(draft)
        if !wasComplete, profile?.isComplete == true { await backend.track(.onboardingCompleted) }
        await reloadAccount()
    }

    func savePrivate(instagram: String, verifiedOnly: Bool) async throws {
        try await backend.savePrivate(instagramHandle: instagram, verifiedOnlyDiscovery: verifiedOnly)
        await reloadAccount()
    }

    func signOut() async {
        try? await backend.signOut()
        resetToSignedOut()
    }

    func deleteAccount() async throws {
        try await backend.deleteAccount()
        revealedMatchIDs = []
        resetToSignedOut()
    }

    // MARK: Pulse intents

    func startPulse(spaceID: UUID, durationMinutes: Int?, untilEventEnd: Bool, availability: Availability) async throws {
        pulse = try await backend.startPulse(spaceID: spaceID, durationMinutes: durationMinutes,
                                             untilEventEnd: untilEventEnd, availability: availability)
        sessionExpiredNotice = false
        feedback.play(.pulseOn)
        await backend.track(.pulseStarted)
        await reloadAccount()
    }

    func pausePulse() async throws {
        pulse = try await backend.pausePulse()
        around = []
        feedback.play(.tap)
    }

    func resumePulse() async throws {
        do {
            pulse = try await backend.resumePulse()
            feedback.play(.tap)
            await refreshSocial()
        } catch CrushlyError.sessionExpired {
            await reloadAccount()
            throw CrushlyError.sessionExpired
        }
    }

    func endPulse() async throws {
        try await backend.endPulse()
        pulse = nil
        around = []
        feedback.play(.tap)
        await reloadAccount()
    }

    func enterSpaceCode(_ code: String) async throws -> CampusSpace {
        let space = try await backend.enterSpaceCode(code)
        if !spaces.contains(space) { spaces.append(space) }
        return space
    }

    func loadSpaces() async {
        await perform { spaces = try await backend.spaces() }
    }

    // MARK: Signal intents

    func sendHeartSignal(to person: PublicProfile) async throws -> SendSignalResult {
        let result = try await backend.sendHeartSignal(to: person.id)
        await backend.track(.signalSent)
        if case .sent = result { feedback.play(.signalSent) }
        await reloadAccount()
        if case .matched(let matchID, _) = result, let match = matches.first(where: { $0.id == matchID }) {
            var seen = revealedMatchIDs
            if !seen.contains(matchID) {
                seen.insert(matchID)
                revealedMatchIDs = seen
                present(match)
            }
        }
        return result
    }

    // MARK: Connection intents

    func setConnection(_ match: Match, status: ConnectionStatus) async {
        await perform { try await backend.setConnectionStatus(matchID: match.id, status: status) }
        await refreshSocial()
    }

    func sendAction(_ match: Match, kind: ConnectionActionKind, detail: String? = nil) async {
        if await perform({ try await backend.sendConnectionAction(matchID: match.id, kind: kind, detail: detail) }) {
            feedback.play(.success)
            await backend.track(.connectionActionSent)
        }
        await refreshSocial()
    }

    func respond(to action: ConnectionAction, accept: Bool) async {
        await perform { try await backend.respondConnectionAction(actionID: action.id, accept: accept) }
        await refreshSocial()
    }

    func instagram(for match: Match) async -> String? {
        try? await backend.instagramHandle(matchID: match.id)
    }

    func requestFind(_ match: Match, meetingPoint: String) async {
        if await perform({ try await backend.requestFind(matchID: match.id, meetingPoint: meetingPoint) }) {
            await backend.track(.findRequested)
        }
        await refreshSocial()
    }

    func respondFind(_ request: FindRequest, accept: Bool) async {
        await perform { try await backend.respondFind(requestID: request.id, accept: accept) }
        await refreshSocial()
    }

    func cancelFind(_ request: FindRequest) async {
        await perform { try await backend.cancelFind(requestID: request.id) }
        await refreshSocial()
    }

    func completeFind(_ request: FindRequest) async {
        await perform { try await backend.completeFind(requestID: request.id) }
        feedback.play(.success)
        await refreshSocial()
    }

    // MARK: Safety intents

    func enterShield(minutes: Int?) async throws {
        shield = try await backend.enterShield(durationMinutes: minutes)
        pulse = nil
        around = []
        await backend.track(.shieldEntered)
        await reloadAccount()
    }

    func exitShield() async throws {
        try await backend.exitShield()
        shield = nil
        await reloadAccount()
    }

    func block(_ userID: UUID) async throws {
        try await backend.block(userID: userID)
        around.removeAll { $0.id == userID }
        await refreshSocial()
        blocked = (try? await backend.blockedUsers()) ?? blocked
    }

    func unblock(_ userID: UUID) async throws {
        try await backend.unblock(userID: userID)
        blocked = (try? await backend.blockedUsers()) ?? blocked
        await refreshSocial()
    }

    func loadBlocked() async {
        await perform { blocked = try await backend.blockedUsers() }
    }

    func report(_ userID: UUID, category: ReportCategory, details: String) async throws {
        try await backend.report(userID: userID, category: category, details: details)
        around.removeAll { $0.id == userID }
        await refreshSocial()
    }

    func updatePrefs(_ newPrefs: NotificationPrefs) async {
        let old = prefs
        prefs = newPrefs
        if !(await perform({ try await backend.updatePrefs(newPrefs) })) { prefs = old }
    }

    // MARK: Demo controls

    func demoSkipAhead(minutes: Double) async {
        demo?.skipAhead(minutes: minutes)
        await reloadAccount()
    }

    func demoSimulateReview(_ status: ReviewStatus) async {
        demo?.simulatePhotoReview(status)
        await reloadAccount()
    }
}
