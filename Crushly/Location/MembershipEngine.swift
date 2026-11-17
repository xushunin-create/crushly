import Foundation

// On-device campus-space membership and per-visit consent (docs/CAMPUS_SPACES_DESIGN.md §3).
//
// Pure value type: feed it location samples and user/system events, read back its state, the effects it asks the
// app to perform (show the consent sheet, revoke participation), and — while the user has consented — the location
// evidence the app may cite when renewing its 60 s server lease.
//
// Raw samples are held only in memory (the last qualifying fix) and are never logged or persisted.

nonisolated struct LocationSample: Equatable, Sendable {
    var coordinate: GeoPoint
    /// Metres (CLLocation.horizontalAccuracy). Negative = invalid.
    var horizontalAccuracy: Double
    /// When the fix was taken (CLLocation.timestamp), device clock.
    var timestamp: Date
    /// Core Location reported the device as stationary with this update.
    var stationary: Bool = false
}

/// What the device may tell the server about its most recent qualifying fix. No coordinates.
nonisolated struct LocationEvidence: Equatable, Sendable {
    var fixTimestamp: Date
    var fixAge: TimeInterval
    var horizontalAccuracy: Double
    var stationary: Bool

    /// The JSON object the participation RPCs expect (BACKEND_CONTRACT §4).
    var json: [String: Any] {
        ["fix_ts_ms": Int64((fixTimestamp.timeIntervalSince1970 * 1000).rounded()),
         "fix_age_ms": Int64(max(0, fixAge * 1000).rounded()),
         "horizontal_accuracy_m": horizontalAccuracy,
         "stationary": stationary]
    }
}

nonisolated struct MembershipConfig: Equatable, Sendable {
    /// Fixes worse than this are never evidence (server enforces the same value). A zone may override it
    /// (`SpaceZone.maxAccuracyMeters`).
    var maxAccuracy: Double = 30
    /// Extra metres added to the accuracy radius before deciding inside/outside.
    var safetyMargin: Double = 5
    /// Entry stability: this many qualifying fixes for the same space…
    var entryFixes: Int = 2
    /// …at least this far apart…
    var entryMinSpacing: TimeInterval = 5
    /// …all within this window of the first.
    var entryWindow: TimeInterval = 45
    /// Consecutive outside-leaning (centre outside, circle straddling) fixes that count as a confident exit.
    var outsideLeaningExitFixes: Int = 2
    /// A moving fix older than this is not evidence (server: evidence_max_fix_age_seconds).
    var maxEvidenceAge: TimeInterval = 15
    /// While stationary, the last fix may be re-cited for up to this long (server: evidence_stationary_max_fix_age_seconds).
    var stationaryReuseMax: TimeInterval = 300
    /// Stationary re-citing is allowed only if that fix was this many radii (accuracy + margin) from the edge.
    var stationaryDepthFactor: Double = 2

    static let standard = MembershipConfig()
}

nonisolated enum MembershipUnavailableReason: Equatable, Sendable {
    case permissionNotDetermined
    case permissionDenied
    case approximateLocation
    case locationServicesOff
    case matchingPaused
    case signedOut
    /// The user hasn't turned on campus matching on this device (location is not used at all).
    case turnedOff
}

nonisolated enum MembershipState: Equatable, Sendable {
    /// Location can't be used (or the user paused campus matching / is signed out). Invisible.
    case unavailable(MembershipUnavailableReason)
    /// Not in any supported space (or not sure yet). Invisible.
    case outside
    /// Fixes suggest a space; waiting for entry to be stable. Invisible.
    case checking(slug: String)
    /// Confidently in a space; waiting for the user's choice for this visit. Invisible.
    case detected(slug: String, visit: UUID)
    /// User chose to stay invisible for this visit (or went invisible). No further prompts this visit.
    case declined(slug: String, visit: UUID)
    /// User consented for this visit and membership is currently verified.
    case participating(slug: String, visit: UUID)
    /// User consented, but membership can't currently be verified: renewals stop and the lease lapses.
    case unverified(slug: String, visit: UUID)

    var slug: String? {
        switch self {
        case .unavailable, .outside: nil
        case .checking(let s), .detected(let s, _), .declined(let s, _), .participating(let s, _), .unverified(let s, _): s
        }
    }

    var visit: UUID? {
        switch self {
        case .detected(_, let v), .declined(_, let v), .participating(_, let v), .unverified(_, let v): v
        default: nil
        }
    }

    /// The user has consented for the current visit (whether or not it is verified right now).
    var hasConsent: Bool {
        switch self {
        case .participating, .unverified: true
        default: false
        }
    }
}

nonisolated enum MembershipEffect: Equatable, Sendable {
    /// Ask "Open to matching here?" for this visit. Emitted at most once per visit (and again only after the
    /// server lease expired, which requires fresh confirmation).
    case promptConsent(slug: String, visit: UUID)
    /// Revoke server participation now (exit, space change, permission loss, pause, sign-out, go invisible).
    case revoke
}

nonisolated struct MembershipEngine: Sendable {
    let config: MembershipConfig
    private(set) var zones: [SpaceZone]
    private(set) var state: MembershipState = .unavailable(.permissionNotDetermined)

    private var makeVisitID: @Sendable () -> UUID
    private var lastSampleTime: Date?
    private var entry: (slug: String, first: Date, last: Date, count: Int)?
    private var outsideLeaning = 0
    /// Last fix that put the device inside the current space, with its depth from the edge (metres).
    private var lastQualifying: (sample: LocationSample, depth: Double)?
    private var stationaryNow = false
    private var availability: MembershipUnavailableReason? = .permissionNotDetermined

    init(zones: [SpaceZone], config: MembershipConfig = .standard, makeVisitID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.zones = zones
        self.config = config
        self.makeVisitID = makeVisitID
    }

    // MARK: Inputs

    /// Replace the zone list (server refresh). If the current space disappeared or its boundary changed, the visit
    /// ends: consent is tied to a specific boundary version.
    mutating func updateZones(_ newZones: [SpaceZone]) -> [MembershipEffect] {
        let old = zones
        zones = newZones
        guard let slug = state.slug else { return [] }
        let before = old.first { $0.slug == slug }, after = newZones.first { $0.slug == slug }
        guard after == nil || after?.boundaryVersion != before?.boundaryVersion || after?.shape != before?.shape else { return [] }
        return endVisit(to: .outside)
    }

    /// Permission / pause / sign-in changes. `nil` means location is usable.
    mutating func setUnavailable(_ reason: MembershipUnavailableReason?) -> [MembershipEffect] {
        availability = reason
        if let reason {
            return endVisit(to: .unavailable(reason))
        }
        if case .unavailable = state { state = .outside }
        return []
    }

    mutating func ingest(_ sample: LocationSample) -> [MembershipEffect] {
        guard availability == nil else { return [] }
        // Delayed or out-of-order fixes never move the state backwards.
        if let last = lastSampleTime, sample.timestamp <= last { return [] }
        lastSampleTime = sample.timestamp
        stationaryNow = sample.stationary

        switch classify(sample) {
        case .inside(let slug, let depth):
            return handleInside(slug, depth: depth, sample: sample)
        case .outside:
            outsideLeaning = 0
            return handleExit()
        case .outsideLeaning:
            outsideLeaning += 1
            if state.visit != nil, outsideLeaning >= config.outsideLeaningExitFixes { return handleExit() }
            return handleUncertain(at: sample.timestamp)
        case .uncertain:
            return handleUncertain(at: sample.timestamp)
        }
    }

    /// Core Location says the device stopped (or started) moving, without necessarily delivering a new fix.
    mutating func setStationary(_ stationary: Bool) {
        stationaryNow = stationary
    }

    /// Periodic check (the app calls this on its renewal timer). Demotes to `unverified` when evidence went stale.
    mutating func tick(now: Date) -> [MembershipEffect] {
        if case .participating(let slug, let visit) = state, evidence(now: now) == nil {
            state = .unverified(slug: slug, visit: visit)
        }
        if case .checking = state, let e = entry, now.timeIntervalSince(e.first) > config.entryWindow {
            entry = nil
            state = .outside
        }
        return []
    }

    // MARK: User decisions

    /// "Open to matching" for the given visit. Returns false (and changes nothing) if that visit is no longer
    /// current — a stale sheet can never grant consent for a different visit or space.
    mutating func consent(visit: UUID) -> Bool {
        switch state {
        case .detected(let slug, let v) where v == visit, .declined(let slug, let v) where v == visit:
            state = .participating(slug: slug, visit: v)
            return true
        default:
            return false
        }
    }

    /// "Stay invisible", dismissing the sheet, or ignoring it.
    mutating func decline(visit: UUID) {
        if case .detected(let slug, let v) = state, v == visit { state = .declined(slug: slug, visit: v) }
    }

    /// "Go invisible" while participating. The visit continues; no re-prompt this visit.
    mutating func goInvisible() -> [MembershipEffect] {
        guard state.hasConsent, let slug = state.slug, let visit = state.visit else { return [] }
        state = .declined(slug: slug, visit: visit)
        return [.revoke]
    }

    /// The server lease expired (or was revoked server-side). Fresh confirmation is required to resume.
    mutating func leaseLost() -> [MembershipEffect] {
        guard state.hasConsent, let slug = state.slug, let visit = state.visit else { return [] }
        state = .detected(slug: slug, visit: visit)
        return [.promptConsent(slug: slug, visit: visit)]
    }

    // MARK: Evidence

    /// Evidence for a renewal right now, or nil if membership isn't currently verified (then don't renew).
    func evidence(now: Date) -> LocationEvidence? {
        guard case .participating(let slug, _) = state, let q = lastQualifying else { return nil }
        let age = now.timeIntervalSince(q.sample.timestamp)
        guard age >= 0, q.sample.horizontalAccuracy <= accuracyLimit(slug) else { return nil }
        if age <= config.maxEvidenceAge {
            return LocationEvidence(fixTimestamp: q.sample.timestamp, fixAge: age,
                                    horizontalAccuracy: q.sample.horizontalAccuracy, stationary: false)
        }
        if stationaryNow, age <= config.stationaryReuseMax, q.depth >= requiredStationaryDepth(slug, accuracy: q.sample.horizontalAccuracy) {
            return LocationEvidence(fixTimestamp: q.sample.timestamp, fixAge: age,
                                    horizontalAccuracy: q.sample.horizontalAccuracy, stationary: true)
        }
        return nil
    }

    /// Evidence for the initial "open" request: must be a fresh, non-stationary qualifying fix.
    func openingEvidence(now: Date) -> LocationEvidence? {
        guard let q = lastQualifying, let slug = state.slug else { return nil }
        let age = now.timeIntervalSince(q.sample.timestamp)
        guard age >= 0, age <= config.maxEvidenceAge, q.sample.horizontalAccuracy <= accuracyLimit(slug) else { return nil }
        return LocationEvidence(fixTimestamp: q.sample.timestamp, fixAge: age,
                                horizontalAccuracy: q.sample.horizontalAccuracy, stationary: false)
    }

    /// The accuracy limit for a zone (its own override, else the global one).
    private func accuracyLimit(_ slug: String) -> Double {
        zones.first { $0.slug == slug }?.maxAccuracy(default: config.maxAccuracy) ?? config.maxAccuracy
    }

    /// How deep inside a fix must have been to be re-cited while stationary. `circle` zones: a couple of accuracy
    /// radii from the edge. `point` zones (buildings) are too small for that, and people sit still indoors, so the
    /// fix's position only has to be at least the safety margin inside.
    private func requiredStationaryDepth(_ slug: String, accuracy: Double) -> Double {
        if zones.first(where: { $0.slug == slug })?.membershipRule == .point { return config.safetyMargin }
        return config.stationaryDepthFactor * (accuracy + config.safetyMargin)
    }

    // MARK: Classification

    enum Verdict: Equatable {
        case inside(slug: String, depth: Double)
        case outside
        /// The fix itself is outside every zone but its circle touches one.
        case outsideLeaning
        /// Poor accuracy, inside-but-near-the-edge, or inside more than one zone.
        case uncertain
    }

    func classify(_ sample: LocationSample) -> Verdict {
        let accuracy = sample.horizontalAccuracy
        let enabled = zones.filter(\.enabled)
        // Too coarse for every zone: say nothing (never an entry, never an exit).
        guard accuracy >= 0, accuracy.isFinite,
              accuracy <= (enabled.map { $0.maxAccuracy(default: config.maxAccuracy) }.max() ?? config.maxAccuracy)
        else { return .uncertain }
        let radius = accuracy + config.safetyMargin
        var insideSlugs: [(String, Double)] = []
        var anyStraddleInside = false, anyStraddleOutside = false
        for zone in enabled {
            // A fix too coarse for this zone can't put you in it, but it still can't rule the zone out either.
            let tooCoarse = accuracy > zone.maxAccuracy(default: config.maxAccuracy)
            switch zone.membershipRule {
            case .circle:
                switch zone.shape.relation(of: sample.coordinate, radius: radius) {
                case .outside: break
                case _ where tooCoarse: anyStraddleInside = true
                case .inside: insideSlugs.append((zone.slug, zone.shape.distanceToBoundary(from: sample.coordinate)))
                case .straddling(let centerInside): if centerInside { anyStraddleInside = true } else { anyStraddleOutside = true }
                }
            case .point:
                let depth = zone.shape.distanceToBoundary(from: sample.coordinate)
                let inside = zone.shape.contains(sample.coordinate)
                if !inside && depth >= radius { break }
                if tooCoarse { anyStraddleInside = true }
                else if inside { insideSlugs.append((zone.slug, depth)) }
                else { anyStraddleOutside = true }   // just outside the walls: leaning out, not yet a confident exit
            }
        }
        if insideSlugs.count == 1, !anyStraddleInside, !anyStraddleOutside {
            return .inside(slug: insideSlugs[0].0, depth: insideSlugs[0].1)
        }
        if insideSlugs.isEmpty, !anyStraddleInside { return anyStraddleOutside ? .outsideLeaning : .outside }
        return .uncertain   // never pick a space arbitrarily
    }

    // MARK: Transitions

    private mutating func handleInside(_ slug: String, depth: Double, sample: LocationSample) -> [MembershipEffect] {
        outsideLeaning = 0
        switch state {
        case .participating(let s, let v) where s == slug, .unverified(let s, let v) where s == slug:
            lastQualifying = (sample, depth)
            state = .participating(slug: s, visit: v)
            return []
        case .detected(let s, _) where s == slug, .declined(let s, _) where s == slug:
            lastQualifying = (sample, depth)
            return []
        case .detected, .declined, .participating, .unverified:
            // A different space: the old visit ends first (revoking if consented), then entry starts over.
            var effects = endVisit(to: .outside)
            effects += beginEntry(slug, depth: depth, sample: sample)
            return effects
        case .outside, .checking:
            return beginEntry(slug, depth: depth, sample: sample)
        case .unavailable:
            return []
        }
    }

    private mutating func beginEntry(_ slug: String, depth: Double, sample: LocationSample) -> [MembershipEffect] {
        let t = sample.timestamp
        if let e = entry, e.slug == slug, t.timeIntervalSince(e.first) <= config.entryWindow {
            if t.timeIntervalSince(e.last) >= config.entryMinSpacing {
                entry = (slug, e.first, t, e.count + 1)
            }
        } else {
            entry = (slug, t, t, 1)
        }
        lastQualifying = (sample, depth)
        guard let e = entry, e.count >= config.entryFixes else {
            state = .checking(slug: slug)
            return []
        }
        entry = nil
        let visit = makeVisitID()
        state = .detected(slug: slug, visit: visit)
        return [.promptConsent(slug: slug, visit: visit)]
    }

    private mutating func handleExit() -> [MembershipEffect] {
        switch state {
        case .detected, .declined, .participating, .unverified, .checking: return endVisit(to: .outside)
        case .outside, .unavailable: return []
        }
    }

    private mutating func handleUncertain(at time: Date) -> [MembershipEffect] {
        if case .participating(let s, let v) = state { state = .unverified(slug: s, visit: v) }
        return []
    }

    private mutating func endVisit(to newState: MembershipState) -> [MembershipEffect] {
        let hadConsent = state.hasConsent
        state = newState
        entry = nil
        outsideLeaning = 0
        lastQualifying = nil
        return hadConsent ? [.revoke] : []
    }
}
