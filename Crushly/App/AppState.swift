import Foundation
import Observation
import SwiftUI

/// Single source of truth for authentication, campus-space participation and social state.
/// Views read from here and call intent methods; only AppState talks to the backend and to Core Location.
///
/// Participation flow (docs/CAMPUS_SPACES_DESIGN.md §3–4):
///   location fixes → MembershipEngine (on device) → consent sheet → open_participation (space id + evidence, no
///   coordinates) → renew every 20 s with fresh evidence only → revoke on exit / go invisible / pause / sign-out.
@Observable
final class AppState {
    enum Phase: Equatable {
        case launching
        case signedOut
        case needsTerms
        case needsProfile
        case ready
    }

    enum Tab: Hashable { case spaces, connections, me }

    /// Loop timing. Tests use `.manual` and drive ticks themselves.
    struct Timing {
        var runLoops = true
        var renewInterval: Duration = .seconds(20)
        var pollInterval: Duration = .seconds(15)
        /// Automatic discovery refresh. The server allows 1 call / 15 s and 60 / hour.
        var discoveryInterval: TimeInterval = 90
        static let standard = Timing()
        static let manual = Timing(runLoops: false)
    }

    /// "Open to matching here?" for one specific visit.
    struct ConsentPrompt: Identifiable, Equatable {
        let visit: UUID
        let slug: String
        let spaceName: String
        var id: UUID { visit }
    }

    enum DiscoveryState: Equatable { case idle, loading, quiet, ready }

    /// What the Spaces screen shows about the user's own status.
    enum SpacesStatus: Equatable {
        /// Campus matching is off on this device.
        case off
        /// Location permission is missing or approximate.
        case needsPermission(MembershipUnavailableReason)
        /// Campus matching paused (optionally until a time).
        case paused(until: Date?)
        case outside
        case checking(spaceName: String)
        case awaitingChoice(spaceName: String)
        /// In a space, chose to stay invisible for this visit.
        case invisibleHere(spaceName: String)
        case participating(spaceName: String)
        /// Consented, but location can't be verified right now; the lease will lapse.
        case unverified(spaceName: String)
    }

    struct ActiveLease: Equatable {
        let sessionID: UUID
        let slug: String
        /// Server clock.
        var expiresAt: Date
    }

    // MARK: Environment

    let config: AppConfig
    let backend: CrushlyBackend
    /// Non-nil only in demo mode, for demo controls.
    let demo: DemoBackend?
    let location: LocationProviding
    let feedback = FeedbackService.shared
    let push: PushManager
    @ObservationIgnored let timing: Timing

    /// Demo only: the fake location source behind the demo controls. Always nil in live mode.
    var simulatedLocation: SimulatedLocationProvider? { location as? SimulatedLocationProvider }

    // MARK: Session & account

    private(set) var phase: Phase = .launching
    private(set) var email = ""
    private(set) var userID: UUID?
    private(set) var profile: Profile?
    private(set) var account = PrivateAccount()
    private(set) var preferences = MatchPreferences()
    private(set) var prefs = NotificationPrefs()
    private(set) var rules = AppRules.default
    /// server time − device time; used only for comparing server timestamps (leases, pauses).
    private(set) var clockSkew: TimeInterval = 0

    // MARK: Campus spaces

    private(set) var zones: [SpaceZone] = []
    private(set) var engine: MembershipEngine
    private(set) var participation: ParticipationStatus?
    private(set) var activeLease: ActiveLease?
    var consentPrompt: ConsentPrompt?
    private(set) var isOpening = false
    /// Renewals are failing for network reasons: "Matching paused, reconnecting".
    private(set) var renewalTrouble = false
    /// Device-level choice to let Crushly check for campus spaces while the app is open. Not visibility consent.
    private(set) var campusMatchingOn = UserDefaults.standard.bool(forKey: "crushly.campusMatchingOn") {
        didSet { UserDefaults.standard.set(campusMatchingOn, forKey: "crushly.campusMatchingOn") }
    }
    /// Observable mirror of the location permission, for settings screens.
    private(set) var locationAuthorization: LocationAuthorization = .notDetermined
    @ObservationIgnored private(set) var seq: Int64 = 0
    @ObservationIgnored private var lastSentFix: Date?
    @ObservationIgnored private var lastRenewalAt: Date?
    @ObservationIgnored private var isRenewing = false
    @ObservationIgnored private(set) var locationRunning = false
    @ObservationIgnored private var sceneActive = true

    // MARK: Discovery

    private(set) var candidates: [PublicProfile] = []
    private(set) var discoveryState: DiscoveryState = .idle
    private(set) var interestReceipts = 0
    private(set) var sentInterests: Set<UUID> = []
    private(set) var interestsRemaining: Int?
    @ObservationIgnored private var lastDiscoveryAt: Date?

    // MARK: Social

    private(set) var conversations: [Conversation] = []
    private(set) var conversationsLoaded = false
    /// The inbox failed to load and nothing is shown yet.
    private(set) var conversationsError: String?
    private(set) var blocked: [BlockedUser] = []

    // MARK: Chat

    struct ThreadState: Equatable {
        /// Server-confirmed messages, oldest first.
        var messages: [ChatMessage] = []
        /// Not yet confirmed (sending or failed). Retries reuse the same id.
        var pending: [PendingMessage] = []
        var hasMore = true
        var loading = false
        var error: String?
    }

    static let messagePageSize = 50
    private(set) var threads: [UUID: ThreadState] = [:]
    /// The thread on screen, so pokes refresh it and mark it read.
    @ObservationIgnored private(set) var openThreadID: UUID?
    @ObservationIgnored let messageCache: MessageCache
    @ObservationIgnored private var pokeTask: Task<Void, Never>?

    // MARK: UI coordination

    var selectedTab: Tab = .spaces
    /// Full-screen mutual match reveal. Bottom navigation is hidden while set.
    var revealMatch: Conversation?
    var errorMessage: String?
    private(set) var isOffline = false
    /// Navigation path of the Connections tab (match ids), so notifications can open a conversation.
    var connectionsPath: [UUID] = []
    /// A notification tapped before sign-in finished; applied once the account is ready.
    private(set) var pendingRoute: NotificationRoute?
    private(set) var notificationPermission: PushManager.Permission = .notDetermined
    /// Incremented to ask every open sheet to close (observed by `.closesForReveal()`).
    private(set) var dismissModalsToken = 0

    @ObservationIgnored private var modalDepth = 0
    @ObservationIgnored private var pendingReveal: Conversation?
    @ObservationIgnored private var registeredToken: (user: UUID, token: String)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var renewTask: Task<Void, Never>?
    @ObservationIgnored private var locationTask: Task<Void, Never>?
    @ObservationIgnored private var revokeRetryTask: Task<Void, Never>?
    @ObservationIgnored private var pauseExpiryTask: Task<Void, Never>?

    private var notificationPrimerDismissed = UserDefaults.standard.bool(forKey: "crushly.notificationPrimerDismissed") {
        didSet { UserDefaults.standard.set(notificationPrimerDismissed, forKey: "crushly.notificationPrimerDismissed") }
    }

    private var revealedMatchIDs: Set<UUID> {
        get { Set((UserDefaults.standard.stringArray(forKey: "crushly.revealed") ?? []).compactMap(UUID.init)) }
        set { UserDefaults.standard.set(newValue.map(\.uuidString), forKey: "crushly.revealed") }
    }

    init(config: AppConfig, backend: CrushlyBackend, demo: DemoBackend?, location: LocationProviding,
         push: PushManager = .shared, timing: Timing = .standard, messageCache: MessageCache = .standard()) {
        self.config = config
        self.messageCache = messageCache
        self.backend = backend
        self.demo = demo
        self.location = location
        self.push = push
        self.timing = timing
        engine = MembershipEngine(zones: [])
        push.onToken = { [weak self] _ in Task { await self?.registerDeviceIfNeeded() } }
        push.onRoute = { [weak self] route in self?.open(route) }
        let events = location.events
        locationTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.ingest(event)
            }
        }
    }

    static func make(config: AppConfig = .load()) -> AppState {
        switch config.environment {
        case .demo:
            let args = ProcessInfo.processInfo.arguments
            let demo = DemoBackend(options: .init(seededAccount: args.contains("-CrushlyDemoSeeded")))
            // Simulated location only ever pairs with the in-memory demo backend.
            let location = SimulatedLocationProvider.fromLaunchArguments(args, zones: demo.zones)
            return AppState(config: config, backend: demo, demo: demo, location: location)
        case .live(let url, let key):
            return AppState(config: config, backend: SupabaseBackend(url: url, anonKey: key), demo: nil,
                            location: LocationService())
        }
    }

    // MARK: Derived state

    /// Server-adjusted time, for comparing server timestamps.
    func now() -> Date { Date().addingTimeInterval(clockSkew) }

    var isPausedNow: Bool {
        guard let p = participation, p.matchingPaused else { return false }
        return p.pausedUntil.map { $0 > now() } ?? true
    }

    var isParticipating: Bool {
        guard case .participating = engine.state, let lease = activeLease else { return false }
        return lease.expiresAt > now()
    }

    func spaceName(_ slug: String?) -> String {
        zones.first { $0.slug == slug }?.name ?? SpaceZoneCatalog.bundled().first { $0.slug == slug }?.name ?? "this campus space"
    }

    var spacesStatus: SpacesStatus {
        switch engine.state {
        case .unavailable(let reason):
            switch reason {
            case .matchingPaused: return .paused(until: participation?.pausedUntil)
            case .turnedOff, .signedOut: return .off
            default: return .needsPermission(reason)
            }
        case .outside: return .outside
        case .checking(let slug): return .checking(spaceName: spaceName(slug))
        case .detected(let slug, _): return .awaitingChoice(spaceName: spaceName(slug))
        case .declined(let slug, _): return .invisibleHere(spaceName: spaceName(slug))
        case .participating(let slug, _):
            return isParticipating ? .participating(spaceName: spaceName(slug)) : .unverified(spaceName: spaceName(slug))
        case .unverified(let slug, _): return .unverified(spaceName: spaceName(slug))
        }
    }

    var shouldOfferNotifications: Bool {
        phase == .ready && notificationPermission == .notDetermined && !notificationPrimerDismissed
            && (!sentInterests.isEmpty || !conversations.isEmpty)
    }

    func conversation(with id: UUID) -> Conversation? { conversations.first { $0.id == id } }
    var unreadCount: Int { conversations.filter(\.unread).count }

    // MARK: Lifecycle

    func bootstrap() async {
        guard await backend.restoreSession() != nil else {
            phase = .signedOut
            await syncAvailability()
            return
        }
        await reloadAccount()
        await afterSignIn()
        await refreshNotificationPermission()
        if demo != nil, let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-CrushlyRoute"),
           index + 1 < ProcessInfo.processInfo.arguments.count,
           let route = NotificationRoute(ProcessInfo.processInfo.arguments[index + 1]) {
            open(route)   // demo/test hook that simulates tapping a notification
        }
    }

    /// Zones, reconciliation and loops, once an account is ready.
    private func afterSignIn() async {
        guard phase == .ready else { return }
        await refreshZones()
        await reconcileParticipation()
        startLoops()
        await startPokes()
    }

    /// Content-free realtime pokes → refetch through the RPCs. Polling stays as the fallback.
    private func startPokes() async {
        guard pokeTask == nil, let user = userID else { return }
        let stream = await backend.startPokes(userID: user)
        pokeTask = Task { [weak self] in
            for await poke in stream {
                guard let self else { return }
                await self.handle(poke)
            }
        }
    }

    func handle(_ poke: RealtimePoke) async {
        // Never trust the poke itself: the server decides what (if anything) changed.
        await refreshConversations()
        if poke.kind == .message, let id = poke.matchID, threads[id] != nil {
            await fetchLatest(id)
            if openThreadID == id { await markRead(id) }
        }
    }

    /// Re-reads the account from the backend.
    func reloadAccount() async {
        do {
            let snapshot = try await backend.loadAccount()
            let wasReady = phase == .ready
            apply(snapshot)
            isOffline = false
            if phase == .ready {
                await refreshConversations()
                if !wasReady { await afterSignIn() }
            }
            await syncAvailability()
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
        preferences = snapshot.preferences
        prefs = snapshot.prefs
        clockSkew = snapshot.serverNow.timeIntervalSinceNow
        if snapshot.rules != rules {
            rules = snapshot.rules
            // The engine's thresholds must agree with the server's evidence checks. Rebuilding ends no visit:
            // it only happens while no visit is in progress.
            if engine.config != rules.membershipConfig, engine.state.visit == nil {
                engine = MembershipEngine(zones: usableZones, config: rules.membershipConfig)
            }
        }
        if !account.hasAcceptedCurrentTerms {
            phase = .needsTerms
        } else if profile?.isComplete != true || !preferences.isComplete {
            phase = .needsProfile
        } else {
            phase = .ready
            Task { await registerDeviceIfNeeded() }
            if let route = pendingRoute { open(route) }
        }
    }

    func sceneBecameActive() async {
        sceneActive = true
        guard phase != .launching, phase != .signedOut else { return }
        await reloadAccount()
        // Reconcile before showing any candidates; they are never shown from cache.
        await reconcileParticipation()
        await refreshDiscovery(force: true)
        startLoops()
        await updateLocationRunning()
    }

    func sceneWentBackground() {
        sceneActive = false
        pollTask?.cancel()
        pollTask = nil
        candidates = []
        if discoveryState != .quiet { discoveryState = isParticipating ? .loading : .idle }
        // Keep location (and the renewal loop) running only while the user is opted in: that's what the
        // background activity session and its blue indicator are for.
        Task { await updateLocationRunning() }
    }

    private func startLoops() {
        guard timing.runLoops, phase == .ready else { return }
        if renewTask == nil {
            renewTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: self?.timing.renewInterval ?? .seconds(20))
                    guard let self, !Task.isCancelled else { return }
                    await self.renewalTick()
                }
            }
        }
        if pollTask == nil, sceneActive {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: self?.timing.pollInterval ?? .seconds(15))
                    guard let self, !Task.isCancelled, self.phase == .ready else { continue }
                    await self.refreshConversations()
                }
            }
        }
    }

    private func stopLoops() {
        [pollTask, renewTask, revokeRetryTask, pauseExpiryTask, pokeTask].forEach { $0?.cancel() }
        pollTask = nil; renewTask = nil; revokeRetryTask = nil; pauseExpiryTask = nil; pokeTask = nil
    }

    // MARK: Zones

    private var usableZones: [SpaceZone] { zones.filter { $0.isUsable(allowDrafts: rules.allowDraftSpaces) } }

    /// The server list wins; the bundled copy is only an offline fallback (and only usable zones of it).
    func refreshZones() async {
        do {
            zones = try await backend.zones()
        } catch {
            if zones.isEmpty { zones = SpaceZoneCatalog.bundled() }
        }
        await handle(engine.updateZones(usableZones))
    }

    // MARK: Location → engine

    /// Every location event goes through here (also called directly by tests).
    func ingest(_ event: LocationEvent) async {
        switch event {
        case .sample(let sample):
            let wasUnverified: Bool = { if case .unverified = engine.state { return true }; return false }()
            await handle(engine.ingest(sample))
            #if DEBUG
            FieldValidationRecorder.shared.record(sample, zones: zones, config: engine.config, state: engine.state)
            #endif
            if case .participating = engine.state {
                // Back to verified before the lease lapsed: renew now. Otherwise samples keep renewals going even
                // when the timer is throttled in the background.
                let due = lastRenewalAt.map { Date().timeIntervalSince($0) >= 20 } ?? true
                if wasUnverified || due { await renewIfPossible() }
            }
        case .stationary(let stationary):
            engine.setStationary(stationary)
        case .authorization:
            await syncAvailability()
        case .unavailable:
            break   // the engine demotes to unverified once evidence goes stale
        }
    }

    private var availabilityReason: MembershipUnavailableReason? {
        guard phase == .ready else { return .signedOut }
        if isPausedNow { return .matchingPaused }
        if !campusMatchingOn { return .turnedOff }
        switch location.authorization {
        case .notDetermined: return .permissionNotDetermined
        case .denied: return .permissionDenied
        case .approximate: return .approximateLocation
        case .precise: return nil
        }
    }

    /// Maps sign-in, pause, the device toggle and permission onto the engine, then starts/stops location.
    func syncAvailability() async {
        locationAuthorization = location.authorization
        let reason = availabilityReason
        let current: MembershipUnavailableReason? = { if case .unavailable(let r) = engine.state { return r }; return nil }()
        if reason != current || (reason == nil && current != nil) {
            await handle(engine.setUnavailable(reason), serverAlreadyRevoked: reason == .matchingPaused)
        }
        await updateLocationRunning()
    }

    private func updateLocationRunning() async {
        let authOK = location.authorization == .precise || location.authorization == .notDetermined
        let wants = phase == .ready && campusMatchingOn && !isPausedNow && authOK && (sceneActive || engine.state.hasConsent)
        if wants && !locationRunning {
            location.startUpdates()
            locationRunning = true
        } else if !wants && locationRunning {
            location.stopUpdates()
            locationRunning = false
        }
    }

    private func handle(_ effects: [MembershipEffect], serverAlreadyRevoked: Bool = false) async {
        for effect in effects {
            switch effect {
            case .promptConsent(let slug, let visit):
                consentPrompt = ConsentPrompt(visit: visit, slug: slug, spaceName: spaceName(slug))
            case .revoke:
                await revokeServerParticipation(alreadyRevoked: serverAlreadyRevoked)
            }
        }
        // A sheet for a visit that's no longer awaiting a choice must never grant consent; close it.
        if let prompt = consentPrompt {
            if case .detected(_, let visit) = engine.state, visit == prompt.visit {} else { consentPrompt = nil }
        }
    }

    // MARK: Participation intents

    func turnOnCampusMatching() async {
        campusMatchingOn = true
        location.requestWhenInUse()
        await syncAvailability()
    }

    func turnOffCampusMatching() async {
        campusMatchingOn = false
        await syncAvailability()
    }

    /// Approximate location can't verify a space; ask for temporary precise access with a purpose string.
    func requestPreciseLocation() {
        location.requestTemporaryPreciseAccess()
    }

    /// "Open to matching" for the current visit (from the consent sheet, or the Spaces screen after "Stay invisible").
    func openToMatching() async {
        guard !isOpening, let visit = engine.state.visit, let slug = engine.state.slug,
              let zone = usableZones.first(where: { $0.slug == slug }) else { return }
        switch engine.state {
        case .detected, .declined: break
        default: return
        }
        guard let evidence = engine.openingEvidence(now: Date()) else {
            errorMessage = CrushlyError.locationNotVerified.errorDescription
            return
        }
        isOpening = true
        defer { isOpening = false }
        revokeRetryTask?.cancel()   // a new open replaces any old session server-side
        guard engine.consent(visit: visit) else { return }
        consentPrompt = nil
        do {
            let status = try await backend.myParticipation()
            participation = status
            clockSkew = status.serverNow.timeIntervalSinceNow
            if status.matchingPaused { throw CrushlyError.matchingPaused }
            let lease = try await backend.openParticipation(
                spaceSlug: slug, boundaryVersion: zone.boundaryVersion, consentEpoch: status.consentEpoch,
                clientRequestID: UUID(), evidence: evidence)
            // The user may have left (or gone invisible) while the request was in flight.
            guard engine.state.hasConsent, engine.state.visit == visit else {
                await revokeServerParticipation()
                return
            }
            activeLease = ActiveLease(sessionID: lease.sessionID, slug: slug, expiresAt: lease.leaseExpiresAt)
            clockSkew = lease.serverNow.timeIntervalSinceNow
            seq = 0
            lastSentFix = evidence.fixTimestamp
            lastRenewalAt = Date()
            renewalTrouble = false
            interestsRemaining = rules.interestsPerSession
            location.beginBackgroundParticipation()
            feedback.play(.openToMatching)
            await refreshDiscovery(force: true)
        } catch {
            await handle(engine.goInvisible())
            if case CrushlyError.boundaryOutdated = error { await refreshZones() }
            if case CrushlyError.matchingPaused = error { await reconcileParticipation() }
            handle(error)
        }
    }

    /// "Stay invisible", or dismissing / ignoring the sheet.
    func stayInvisible(visit: UUID) {
        engine.decline(visit: visit)
        if consentPrompt?.visit == visit { consentPrompt = nil }
    }

    /// The visible "Go invisible" button while participating.
    func goInvisible() async {
        await handle(engine.goInvisible())
        feedback.play(.tap)
    }

    func pauseCampusMatching(minutes: Int?) async throws {
        let status = try await backend.setMatchingPaused(true, minutes: minutes)
        participation = status
        clockSkew = status.serverNow.timeIntervalSinceNow
        await syncAvailability()   // pausing already ended the session server-side
        clearParticipationLocal()
        schedulePauseExpiry()
    }

    func resumeCampusMatching() async throws {
        let status = try await backend.setMatchingPaused(false, minutes: nil)
        participation = status
        pauseExpiryTask?.cancel()
        await syncAvailability()
    }

    /// Source of truth on launch and foreground. An old session is never resumed silently.
    func reconcileParticipation() async {
        guard phase == .ready, !isOpening else { return }
        do {
            let status = try await backend.myParticipation()
            participation = status
            clockSkew = status.serverNow.timeIntervalSinceNow
            schedulePauseExpiry()
            if let session = status.session {
                if engine.state.hasConsent, let lease = activeLease, lease.sessionID == session.id {
                    activeLease?.expiresAt = session.leaseExpiresAt
                    seq = max(seq, session.lastSeq)
                } else {
                    // A session this run of the app didn't open for the current visit.
                    await revokeServerParticipation()
                    if engine.state.hasConsent { await handle(engine.leaseLost()) }
                }
            } else if engine.state.hasConsent, activeLease != nil {
                await leaseLost()
            }
            await syncAvailability()
            isOffline = false
        } catch {
            handle(error)
        }
    }

    // MARK: Renewal

    /// The periodic check: demote stale evidence, notice a lapsed lease, renew, refresh receipts/discovery.
    func renewalTick() async {
        guard phase == .ready else { return }
        _ = engine.tick(now: Date())
        guard engine.state.hasConsent, let lease = activeLease else { return }
        if lease.expiresAt <= now() {
            await leaseLost()
            return
        }
        await renewIfPossible()
        if isParticipating {
            await refreshReceipts()
            await refreshDiscovery()
        }
    }

    /// Renews only with evidence the engine vouches for, and only with a fix newer than the last one sent
    /// (unless the device is stationary, when the server allows re-citing it for a while).
    func renewIfPossible() async {
        guard !isRenewing, case .participating = engine.state, let lease = activeLease,
              let evidence = engine.evidence(now: Date()) else { return }
        if !evidence.stationary, let last = lastSentFix, evidence.fixTimestamp <= last { return }
        isRenewing = true
        defer { isRenewing = false }
        seq += 1
        do {
            let result = try await backend.renewParticipation(sessionID: lease.sessionID, seq: seq, evidence: evidence)
            guard activeLease?.sessionID == result.sessionID else { return }
            activeLease?.expiresAt = result.leaseExpiresAt
            clockSkew = result.serverNow.timeIntervalSinceNow
            lastSentFix = evidence.fixTimestamp
            lastRenewalAt = Date()
            renewalTrouble = false
            isOffline = false
        } catch CrushlyError.sessionExpired, CrushlyError.consentStale {
            await leaseLost()
        } catch CrushlyError.staleRequest {
            if let session = try? await backend.myParticipation().session, session.id == lease.sessionID {
                seq = max(seq, session.lastSeq)
            }
        } catch CrushlyError.matchingPaused {
            await reconcileParticipation()
        } catch CrushlyError.staleEvidence, CrushlyError.insufficientAccuracy, CrushlyError.rateLimited {
            // Not renewed; if this persists the lease lapses and the user is invisible within 60 s.
        } catch CrushlyError.notAuthenticated {
            resetToSignedOut()
        } catch {
            renewalTrouble = true   // offline: the 60 s lease is the backstop
            if error is URLError { isOffline = true }
        }
    }

    /// The server lease is gone: fresh confirmation is required.
    private func leaseLost() async {
        location.endBackgroundParticipation()
        clearParticipationLocal()
        await handle(engine.leaseLost())
    }

    private func clearParticipationLocal() {
        activeLease = nil
        candidates = []
        discoveryState = .idle
        interestReceipts = 0
        sentInterests = []
        interestsRemaining = nil
        lastDiscoveryAt = nil
        renewalTrouble = false
    }

    /// Ends server participation. Retried with backoff if offline; the 60 s lease is the backstop either way.
    private func revokeServerParticipation(alreadyRevoked: Bool = false) async {
        location.endBackgroundParticipation()
        clearParticipationLocal()
        await updateLocationRunning()
        guard !alreadyRevoked, phase == .ready || phase == .signedOut else { return }
        revokeRetryTask?.cancel()
        do {
            let epoch = try await backend.revokeParticipation()
            participation?.consentEpoch = epoch
        } catch CrushlyError.notAuthenticated {
            return
        } catch {
            revokeRetryTask = Task { [weak self] in
                for delay in [2.0, 4, 8, 16, 30, 30, 30, 30, 30, 30] {
                    try? await Task.sleep(for: .seconds(delay))
                    guard let self, !Task.isCancelled else { return }
                    if (try? await self.backend.revokeParticipation()) != nil { return }
                }
            }
        }
    }

    private func schedulePauseExpiry() {
        pauseExpiryTask?.cancel()
        guard timing.runLoops, isPausedNow, let until = participation?.pausedUntil else { return }
        let delay = until.timeIntervalSince(now()) + 1
        pauseExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, delay)))
            guard let self, !Task.isCancelled else { return }
            await self.reconcileParticipation()
        }
    }

    // MARK: Discovery

    func refreshDiscovery(force: Bool = false) async {
        guard isParticipating else { return }
        if !force, let last = lastDiscoveryAt, Date().timeIntervalSince(last) < timing.discoveryInterval, discoveryState != .loading {
            return
        }
        if discoveryState == .idle { discoveryState = .loading }
        do {
            let result = try await backend.discoverCandidates()
            lastDiscoveryAt = Date()
            switch result {
            case .quiet:
                candidates = []
                discoveryState = .quiet
            case .candidates(let list):
                let matched = Set(conversations.map(\.other.id))
                candidates = list.filter { !matched.contains($0.id) }
                discoveryState = .ready
            }
            sentInterests = try await backend.sentInterests()
        } catch CrushlyError.rateLimited {
            // Keep the current list.
        } catch CrushlyError.notParticipating {
            await reconcileParticipation()
        } catch {
            handle(error)
        }
    }

    func refreshReceipts() async {
        guard isParticipating else { interestReceipts = 0; return }
        if let count = try? await backend.interestReceipts() { interestReceipts = count }
    }

    func expressInterest(in person: PublicProfile) async throws -> InterestResult {
        do {
            let result = try await backend.expressInterest(in: person.id)
            sentInterests.insert(person.id)
            switch result {
            case .sent(let remaining):
                interestsRemaining = remaining
                feedback.play(.interestSent)
            case .matched(let matchID, let remaining):
                interestsRemaining = remaining
                candidates.removeAll { $0.id == person.id }
                await refreshConversations()
                if let match = conversation(with: matchID), !revealedMatchIDs.contains(matchID) {
                    revealedMatchIDs.insert(matchID)
                    present(match)
                }
            }
            return result
        } catch CrushlyError.notAvailable {
            candidates.removeAll { $0.id == person.id }
            throw CrushlyError.notAvailable
        } catch CrushlyError.notParticipating {
            await reconcileParticipation()
            throw CrushlyError.notParticipating
        }
    }

    // MARK: Conversations

    func refreshConversations() async {
        guard phase == .ready else { return }
        do {
            let incoming = try await backend.conversations()
            detectNewMatches(incoming)
            conversations = incoming
            conversationsLoaded = true
            conversationsError = nil
            isOffline = false
            // my_conversations() is the source of truth: anything else is purged from memory and disk.
            let live = Set(incoming.map(\.id))
            for id in threads.keys where !live.contains(id) { purgeConversationLocal(id) }
            if let user = userID { messageCache.purge(user: user, keeping: live) }
            if let open = openThreadID, !live.contains(open) { purgeConversationLocal(open) }
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(error.code) {
            isOffline = true
            if !conversationsLoaded { conversationsError = CrushlyError.network.errorDescription }
        } catch CrushlyError.notAuthenticated {
            resetToSignedOut()
        } catch {
            if !conversationsLoaded { conversationsError = (error as? LocalizedError)?.errorDescription ?? "Couldn't load conversations." }
            else { handle(error) }
        }
    }

    private func detectNewMatches(_ incoming: [Conversation]) {
        var seen = revealedMatchIDs
        if !conversationsLoaded {
            // First load on this device: don't replay old reveals.
            seen.formUnion(incoming.filter { now().timeIntervalSince($0.createdAt) > 600 }.map(\.id))
        }
        if revealMatch == nil, let fresh = incoming.first(where: { !seen.contains($0.id) }) {
            seen.insert(fresh.id)
            present(fresh)
        }
        revealedMatchIDs = seen
    }

    /// iOS can't show the full-screen reveal on top of an open sheet, so open sheets are asked to close
    /// first and the reveal follows once the last one has gone.
    private func present(_ match: Conversation) {
        if modalDepth > 0 {
            pendingReveal = match
            dismissModalsToken += 1
        } else {
            show(match)
        }
    }

    private func show(_ match: Conversation) {
        revealMatch = match
        feedback.play(.heartSync)
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

    /// Opens a conversation from the reveal.
    func openConversation(_ id: UUID) {
        revealMatch = nil
        selectedTab = .connections
        connectionsPath = [id]
    }

    // MARK: Chat

    func thread(_ id: UUID) -> ThreadState { threads[id] ?? ThreadState() }

    /// Opens a conversation. A cached thread is shown only after `my_conversations()` confirmed it in this run.
    func openThread(_ matchID: UUID) async {
        openThreadID = matchID
        if !conversationsLoaded { await refreshConversations() }
        guard conversation(with: matchID) != nil else {
            purgeConversationLocal(matchID)
            return
        }
        if threads[matchID] == nil {
            var state = ThreadState()
            if let user = userID, let cached = messageCache.load(user: user, match: matchID) {
                state.messages = cached.messages
                // A send that was in flight when the app stopped is shown as failed; retry reuses its id.
                state.pending = cached.pending.map { var p = $0; p.state = .failed; return p }
            }
            threads[matchID] = state
        }
        await fetchLatest(matchID)
        await markRead(matchID)
    }

    func closeThread(_ matchID: UUID) {
        if openThreadID == matchID { openThreadID = nil }
    }

    /// Newest page; merges by id so repeated fetches never duplicate.
    func fetchLatest(_ matchID: UUID) async {
        threads[matchID, default: ThreadState()].loading = true
        do {
            let page = try await backend.fetchMessages(matchID: matchID, before: nil, limit: Self.messagePageSize)
            guard threads[matchID] != nil else { return }
            merge(page, into: matchID)
            if page.count < Self.messagePageSize { threads[matchID]?.hasMore = false }
            threads[matchID]?.error = nil
        } catch CrushlyError.notFound {
            conversationEnded(matchID)
        } catch {
            threads[matchID]?.error = (error is URLError) ? CrushlyError.network.errorDescription : (error as? LocalizedError)?.errorDescription
        }
        threads[matchID]?.loading = false
    }

    /// Keyset pagination backwards from the oldest message we have.
    func loadOlder(_ matchID: UUID) async {
        guard let state = threads[matchID], state.hasMore, !state.loading, let oldest = state.messages.first else { return }
        threads[matchID]?.loading = true
        do {
            let page = try await backend.fetchMessages(matchID: matchID, before: MessageCursor(createdAt: oldest.createdAt, id: oldest.id),
                                                       limit: Self.messagePageSize)
            merge(page, into: matchID)
            if page.count < Self.messagePageSize { threads[matchID]?.hasMore = false }
        } catch CrushlyError.notFound {
            conversationEnded(matchID)
        } catch {
            threads[matchID]?.error = (error is URLError) ? CrushlyError.network.errorDescription : (error as? LocalizedError)?.errorDescription
        }
        threads[matchID]?.loading = false
    }

    private func merge(_ page: [ChatMessage], into matchID: UUID) {
        guard var state = threads[matchID] else { return }
        var byID = Dictionary(state.messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for message in page { byID[message.id] = message }
        state.messages = byID.values.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        let confirmed = Set(byID.keys)
        state.pending.removeAll { confirmed.contains($0.id) }
        threads[matchID] = state
        persist(matchID)
    }

    private func persist(_ matchID: UUID) {
        guard let user = userID, let state = threads[matchID] else { return }
        messageCache.save(CachedThread(messages: state.messages, pending: state.pending), user: user, match: matchID)
    }

    func sendMessage(_ body: String, in matchID: UUID) async {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.count <= rules.messageMaxChars else {
            errorMessage = "Messages can be up to \(rules.messageMaxChars) characters."
            return
        }
        let pending = PendingMessage(id: UUID(), body: trimmed, createdAt: Date(), state: .sending)
        threads[matchID, default: ThreadState()].pending.append(pending)
        persist(matchID)
        await deliver(pending.id, in: matchID)
    }

    /// Retries with the SAME client message id, so a send that actually landed is never duplicated.
    func retry(_ pendingID: UUID, in matchID: UUID) async {
        guard let index = threads[matchID]?.pending.firstIndex(where: { $0.id == pendingID }) else { return }
        threads[matchID]?.pending[index].state = .sending
        await deliver(pendingID, in: matchID)
    }

    func discardPending(_ pendingID: UUID, in matchID: UUID) {
        threads[matchID]?.pending.removeAll { $0.id == pendingID }
        persist(matchID)
    }

    private func deliver(_ pendingID: UUID, in matchID: UUID) async {
        guard let pending = threads[matchID]?.pending.first(where: { $0.id == pendingID }) else { return }
        do {
            let receipt = try await backend.sendMessage(matchID: matchID, clientMessageID: pending.id, body: pending.body)
            guard threads[matchID] != nil else { return }
            threads[matchID]?.pending.removeAll { $0.id == pendingID }
            merge([ChatMessage(id: receipt.id, senderIsMe: true, body: pending.body, createdAt: receipt.createdAt)], into: matchID)
            if let index = conversations.firstIndex(where: { $0.id == matchID }) {
                conversations[index].lastMessageAt = receipt.createdAt
                conversations[index].lastMessagePreview = String(pending.body.prefix(80))
                conversations[index].lastMessageFromMe = true
            }
        } catch CrushlyError.notFound {
            // The match is gone (left, blocked, deleted). A queued send must never recreate anything.
            conversationEnded(matchID)
        } catch {
            if let index = threads[matchID]?.pending.firstIndex(where: { $0.id == pendingID }) {
                threads[matchID]?.pending[index].state = .failed
                persist(matchID)
            }
            if case CrushlyError.rateLimited = error { handle(error) }
        }
    }

    func markRead(_ matchID: UUID) async {
        guard let index = conversations.firstIndex(where: { $0.id == matchID }) else { return }
        conversations[index].unread = false
        try? await backend.markConversationRead(matchID: matchID)
    }

    /// "Leave & delete conversation": ends the match and deletes history for both people.
    func leaveConversation(_ matchID: UUID) async throws {
        do {
            try await backend.leaveConversation(matchID: matchID)
        } catch CrushlyError.notFound {
            // Already gone; purge locally all the same.
        }
        purgeConversationLocal(matchID)
        await backend.track(.conversationLeft)
    }

    private func conversationEnded(_ matchID: UUID) {
        let wasOpen = openThreadID == matchID
        purgeConversationLocal(matchID)
        if wasOpen { errorMessage = "This conversation has ended." }
    }

    /// Removes a conversation from memory, pending sends and the on-device cache, and closes it if it's on screen.
    private func purgeConversationLocal(_ matchID: UUID) {
        threads[matchID] = nil
        conversations.removeAll { $0.id == matchID }
        if let user = userID { messageCache.purge(user: user, match: matchID) }
        connectionsPath.removeAll { $0 == matchID }
        if openThreadID == matchID { openThreadID = nil }
        if revealMatch?.id == matchID { revealMatch = nil }
    }

    private func purgeConversations(with userID: UUID) {
        for conversation in conversations where conversation.other.id == userID { purgeConversationLocal(conversation.id) }
    }

    // MARK: Notifications & routing

    func enableNotifications() async {
        notificationPermission = await push.requestPermission()
        notificationPrimerDismissed = true
    }

    func dismissNotificationPrimer() {
        notificationPrimerDismissed = true
    }

    func refreshNotificationPermission() async {
        notificationPermission = await push.refreshPermission()
    }

    /// Opens the screen a notification points to, deferring until the account is ready.
    /// Opening a notification never grants consent to anything.
    func open(_ route: NotificationRoute) {
        guard phase == .ready else {
            pendingRoute = route
            return
        }
        pendingRoute = nil
        revealMatch = nil
        selectedTab = .connections
        switch route {
        case .connections:
            connectionsPath = []
        case .match(let id):
            connectionsPath = [id]
        }
        Task { await refreshConversations() }
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
        stopLoops()
        location.endBackgroundParticipation()
        if locationRunning { location.stopUpdates(); locationRunning = false }
        _ = engine.setUnavailable(.signedOut)
        phase = .signedOut
        email = ""; userID = nil; profile = nil; account = PrivateAccount(); preferences = MatchPreferences()
        participation = nil; consentPrompt = nil
        clearParticipationLocal()
        conversations = []; conversationsLoaded = false; conversationsError = nil; blocked = []; revealMatch = nil
        threads = [:]; openThreadID = nil
        selectedTab = .spaces
        connectionsPath = []
        registeredToken = nil
    }

    /// Sign-out and account deletion revoke participation first.
    private func endParticipationBeforeLeaving() async {
        revokeRetryTask?.cancel()
        location.endBackgroundParticipation()
        if locationRunning { location.stopUpdates(); locationRunning = false }
        _ = engine.setUnavailable(.signedOut)
        consentPrompt = nil
        clearParticipationLocal()
        _ = try? await backend.revokeParticipation()
    }

    // MARK: Auth intents

    func requestCode(email: String, createAccount: Bool = true) async throws {
        guard rules.isAllowedEmail(email) else { throw CrushlyError.domainNotAllowed }
        try await backend.requestCode(email: email.lowercased().trimmingCharacters(in: .whitespaces),
                                      createAccount: createAccount)
    }

    func verifyCode(email: String, code: String) async throws {
        try await backend.verifyCode(email: email.lowercased().trimmingCharacters(in: .whitespaces),
                                     code: code.trimmingCharacters(in: .whitespaces))
        await reloadAccount()
    }

    func acceptTerms() async throws {
        try await backend.acceptTerms(termsVersion: LegalDocuments.termsVersion,
                                      privacyVersion: LegalDocuments.privacyVersion, ageConfirmed: true)
        await reloadAccount()
    }

    /// Saves the profile and (if given) matching preferences together, then re-reads the account.
    func saveProfile(_ draft: Profile, preferences newPreferences: MatchPreferences? = nil) async throws {
        let wasReady = phase == .ready
        profile = try await backend.saveProfile(draft)
        if let newPreferences, newPreferences != preferences {
            try await backend.updateMatchPreferences(newPreferences)
        }
        if !wasReady, profile?.isComplete == true, (newPreferences ?? preferences).isComplete {
            await backend.track(.onboardingCompleted)
        } else {
            await backend.track(.profileUpdated)
        }
        await reloadAccount()
    }

    func saveVerifiedOnly(_ enabled: Bool) async throws {
        try await backend.saveVerifiedOnlyDiscovery(enabled)
        await reloadAccount()
    }

    func signOut() async {
        await endParticipationBeforeLeaving()
        if let user = userID { messageCache.purgeAll(user: user) }
        await backend.stopPokes()
        if let token = push.deviceToken { try? await backend.unregisterDevice(token: token) }
        try? await backend.signOut()
        resetToSignedOut()
    }

    func deleteAccount() async throws {
        await endParticipationBeforeLeaving()
        try await backend.deleteAccount()
        if let user = userID { messageCache.purgeAll(user: user) }
        await backend.stopPokes()
        revealedMatchIDs = []
        resetToSignedOut()
    }

    // MARK: Safety intents

    func block(_ userID: UUID) async throws {
        try await backend.block(userID: userID)
        candidates.removeAll { $0.id == userID }
        purgeConversations(with: userID)
        await backend.track(.userBlocked)
        await refreshConversations()
        blocked = (try? await backend.blockedUsers()) ?? blocked
    }

    func unblock(_ userID: UUID) async throws {
        try await backend.unblock(userID: userID)
        await backend.track(.userUnblocked)
        blocked = (try? await backend.blockedUsers()) ?? blocked
    }

    func loadBlocked() async {
        await perform { blocked = try await backend.blockedUsers() }
    }

    func report(_ userID: UUID, category: ReportCategory, details: String, evidenceMessageIDs: [UUID] = []) async throws {
        try await backend.report(userID: userID, category: category, details: details, evidenceMessageIDs: evidenceMessageIDs)
        candidates.removeAll { $0.id == userID }
        purgeConversations(with: userID)
        await backend.track(.userReported)
        await refreshConversations()
    }

    func updatePrefs(_ newPrefs: NotificationPrefs) async {
        let old = prefs
        prefs = newPrefs
        if await perform({ try await backend.updatePrefs(newPrefs) }) {
            await backend.track(.notificationPrefsChanged)
        } else {
            prefs = old
        }
    }

    // MARK: Demo controls (DemoBackend + simulated location only)

    func demoSkipAhead(minutes: Double) async {
        demo?.skipAhead(minutes: minutes)
        await reloadAccount()
        await renewalTick()
    }

    func demoSimulateReview(_ status: ReviewStatus) async {
        demo?.simulatePhotoReview(status)
        await reloadAccount()
    }

    func demoMove(to place: SimulatedLocationProvider.Place) {
        simulatedLocation?.move(to: place)
    }

    func demoSetLocationAuthorization(_ value: LocationAuthorization) {
        simulatedLocation?.setAuthorization(value)
    }
}
