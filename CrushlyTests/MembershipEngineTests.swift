import Foundation
import Testing
@testable import Crushly

// Privacy-critical on-device behaviour (docs/CAMPUS_SPACES_DESIGN.md §3). Synthetic square zones around an
// arbitrary origin; no real campus coordinates.

private let origin = GeoPoint(latitude: 10, longitude: 10)
private let projection = LocalProjection(origin: origin)

/// A point `x` metres east and `y` metres north of the origin.
private func at(_ x: Double, _ y: Double) -> GeoPoint { projection.unproject(.init(x: x, y: y)) }

private func square(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [GeoPoint] {
    [at(x0, y0), at(x1, y0), at(x1, y1), at(x0, y1), at(x0, y0)]
}

private func zone(_ slug: String, _ rings: [[GeoPoint]], version: Int = 1) -> SpaceZone {
    SpaceZone(slug: slug, name: slug, subtitle: nil, shape: ZoneShape(rings: rings), boundaryVersion: version,
              validationStatus: .draft, enabled: true, sortOrder: 0)
}

/// Zone A: 100 m square at (0,0)–(100,100). Zone B: 100 m square at (300,0)–(400,100).
private let zoneA = zone("a", [square(0, 0, 100, 100)])
private let zoneB = zone("b", [square(300, 0, 400, 100)])

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func fix(_ x: Double, _ y: Double, at seconds: Double, accuracy: Double = 5, stationary: Bool = false) -> LocationSample {
    LocationSample(coordinate: at(x, y), horizontalAccuracy: accuracy, timestamp: t0.addingTimeInterval(seconds), stationary: stationary)
}

private final class VisitIDs: @unchecked Sendable {
    private var n = 0
    func next() -> UUID { n += 1; return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }
}

/// An engine with location available, already stably inside zone A with a pending prompt.
private func detectedInA(_ ids: VisitIDs = VisitIDs()) -> (MembershipEngine, UUID) {
    var e = MembershipEngine(zones: [zoneA, zoneB], makeVisitID: ids.next)
    _ = e.setUnavailable(nil)
    _ = e.ingest(fix(50, 50, at: 0))
    _ = e.ingest(fix(50, 51, at: 6))
    return (e, e.state.visit!)
}

private func participatingInA() -> (MembershipEngine, UUID) {
    var (e, visit) = detectedInA()
    let r1 = e.consent(visit: visit)
    #expect(r1)
    return (e, visit)
}

struct GeometryTests {
    @Test func classifiesWholeAccuracyCircle() {
        let shape = zoneA.shape
        #expect(shape.relation(of: at(50, 50), radius: 10) == .inside)
        #expect(shape.relation(of: at(-200, 50), radius: 10) == .outside)
        #expect(shape.relation(of: at(95, 50), radius: 10) == .straddling(centerInside: true))
        #expect(shape.relation(of: at(105, 50), radius: 10) == .straddling(centerInside: false))
        // A corner poking toward an outside fix is caught even between samples.
        #expect(shape.relation(of: at(103, 103), radius: 5) == .straddling(centerInside: false))
    }

    @Test func abuttingPolygonsOfOneZoneHaveNoSeam() {
        let joined = ZoneShape(rings: [square(0, 0, 100, 100), square(100, 0, 200, 100)])
        #expect(joined.relation(of: at(100, 50), radius: 20) == .inside)
        #expect(joined.relation(of: at(195, 50), radius: 20) == .straddling(centerInside: true))
    }

    @Test func distances() {
        #expect(abs(zoneA.shape.distanceToBoundary(from: at(50, 30)) - 30) < 0.5)
        #expect(abs(zoneA.shape.minimumDistance(to: zoneB.shape) - 200) < 0.5)
        #expect(zoneA.shape.minimumDistance(to: zone("c", [square(50, 50, 150, 150)]).shape) == 0)
    }

    @Test func projectionRoundTrips() {
        let p = at(123.4, -56.7)
        let v = projection.project(p)
        #expect(abs(v.x - 123.4) < 0.01 && abs(v.y + 56.7) < 0.01)
    }
}

struct MembershipEngineTests {
    // MARK: Invisible by default, stable entry

    @Test func startsUnavailableAndInvisible() {
        var e = MembershipEngine(zones: [zoneA])
        #expect(e.state == .unavailable(.permissionNotDetermined))
        let r2 = e.ingest(fix(50, 50, at: 0))
        #expect(r2.isEmpty)
        #expect(e.state == .unavailable(.permissionNotDetermined))
        _ = e.setUnavailable(nil)
        #expect(e.state == .outside)
        #expect(e.evidence(now: t0) == nil)
    }

    @Test func entryNeedsTwoSpacedFixesThenPromptsOnce() {
        let ids = VisitIDs()
        var e = MembershipEngine(zones: [zoneA], makeVisitID: ids.next)
        _ = e.setUnavailable(nil)
        let r3 = e.ingest(fix(50, 50, at: 0))
        #expect(r3.isEmpty)
        #expect(e.state == .checking(slug: "a"))
        let r4 = e.ingest(fix(50, 50, at: 2))
        #expect(r4.isEmpty, "fixes closer than 5 s don't count twice")
        let effects = e.ingest(fix(50, 52, at: 7))
        guard case .detected("a", let visit) = e.state else { Issue.record("expected detected"); return }
        #expect(effects == [.promptConsent(slug: "a", visit: visit)])
        let r5 = e.ingest(fix(50, 53, at: 20))
        #expect(r5.isEmpty, "no second prompt during the same visit")
        #expect(e.evidence(now: t0.addingTimeInterval(20)) == nil, "detected but not consented: no evidence")
    }

    @Test func entryWindowExpires() {
        var e = MembershipEngine(zones: [zoneA])
        _ = e.setUnavailable(nil)
        _ = e.ingest(fix(50, 50, at: 0))
        _ = e.tick(now: t0.addingTimeInterval(50))
        #expect(e.state == .outside)
        _ = e.ingest(fix(50, 50, at: 60))
        #expect(e.state == .checking(slug: "a"), "a late fix starts entry over rather than completing it")
    }

    @Test func poorAccuracyAndEdgeFixesNeverEnter() {
        var e = MembershipEngine(zones: [zoneA])
        _ = e.setUnavailable(nil)
        for i in 0..<10 { _ = e.ingest(fix(50, 50, at: Double(i) * 10, accuracy: 31)) }
        #expect(e.state == .outside, "accuracy worse than 30 m is never evidence")
        for i in 0..<10 { _ = e.ingest(fix(97, 50, at: 200 + Double(i) * 10)) }
        #expect(e.state == .outside, "the edge of a space is a dead zone")
    }

    @Test func overlappingZonesAreNeverPickedArbitrarily() {
        var e = MembershipEngine(zones: [zoneA, zone("overlap", [square(0, 0, 100, 100)])])
        _ = e.setUnavailable(nil)
        for i in 0..<5 { _ = e.ingest(fix(50, 50, at: Double(i) * 10)) }
        #expect(e.state == .outside)
    }

    @Test func outOfOrderFixesAreIgnored() {
        var (e, _) = participatingInA()
        _ = e.ingest(fix(50, 50, at: 30))
        let r6 = e.ingest(fix(-500, -500, at: 10))
        #expect(r6.isEmpty, "a delayed old fix can't cause an exit or anything else")
        #expect(e.state.hasConsent)
    }

    // MARK: Consent is per visit

    @Test func consentOnlyForTheCurrentVisit() {
        var (e, visit) = detectedInA()
        let r7 = e.consent(visit: UUID())
        #expect(!r7, "a stale sheet can't grant consent")
        #expect(e.state == .detected(slug: "a", visit: visit))
        let r8 = e.consent(visit: visit)
        #expect(r8)
        #expect(e.state == .participating(slug: "a", visit: visit))
    }

    @Test func declineMeansNoMorePromptsThisVisit() {
        var (e, visit) = detectedInA()
        e.decline(visit: visit)
        #expect(e.state == .declined(slug: "a", visit: visit))
        for i in 0..<5 { let r9 = e.ingest(fix(50, 50, at: 20 + Double(i) * 10)); #expect(r9.isEmpty) }
        #expect(e.state == .declined(slug: "a", visit: visit))
    }

    @Test func goInvisibleRevokesAndDoesNotRePrompt() {
        var (e, visit) = participatingInA()
        let r10 = e.goInvisible()
        #expect(r10 == [.revoke])
        #expect(e.state == .declined(slug: "a", visit: visit))
        let r11 = e.ingest(fix(50, 50, at: 30))
        #expect(r11.isEmpty)
        #expect(e.evidence(now: t0.addingTimeInterval(30)) == nil)
    }

    @Test func movingToAnotherSpaceRevokesFirstAndAsksAgain() {
        var (e, visitA) = participatingInA()
        let first = e.ingest(fix(350, 50, at: 30))
        #expect(first == [.revoke], "leaving A for B revokes A before anything else")
        #expect(e.state == .checking(slug: "b"))
        let second = e.ingest(fix(350, 52, at: 36))
        guard case .detected("b", let visitB) = e.state else { Issue.record("expected detected in b"); return }
        #expect(visitB != visitA)
        #expect(second == [.promptConsent(slug: "b", visit: visitB)])
        let r12 = e.consent(visit: visitA)
        #expect(!r12, "consent from A never transfers to B")
    }

    @Test func reEnteringIsANewVisit() {
        var (e, visit) = detectedInA()
        e.decline(visit: visit)
        _ = e.ingest(fix(-300, 50, at: 20))
        #expect(e.state == .outside)
        _ = e.ingest(fix(50, 50, at: 40)); _ = e.ingest(fix(50, 50, at: 46))
        #expect(e.state.visit != nil && e.state.visit != visit)
    }

    // MARK: Exit and uncertainty

    @Test func confidentExitRevokesImmediately() {
        var (e, _) = participatingInA()
        let r13 = e.ingest(fix(-200, 50, at: 20))
        #expect(r13 == [.revoke])
        #expect(e.state == .outside)
    }

    @Test func outsideLeaningTwiceIsAnExit() {
        var (e, visit) = participatingInA()
        let r14 = e.ingest(fix(103, 50, at: 20))
        #expect(r14.isEmpty)
        #expect(e.state == .unverified(slug: "a", visit: visit), "one ambiguous fix only pauses")
        let r15 = e.ingest(fix(104, 50, at: 26))
        #expect(r15 == [.revoke])
        #expect(e.state == .outside)
    }

    @Test func uncertaintyPausesAndRecovers() {
        var (e, visit) = participatingInA()
        _ = e.ingest(fix(50, 50, at: 20, accuracy: 60))
        #expect(e.state == .unverified(slug: "a", visit: visit))
        #expect(e.evidence(now: t0.addingTimeInterval(21)) == nil, "no renewals while unverified")
        _ = e.ingest(fix(50, 50, at: 30))
        #expect(e.state == .participating(slug: "a", visit: visit), "same visit resumes before the lease lapses")
    }

    @Test func permissionLossRevokesAndRequiresFreshEntry() {
        var (e, _) = participatingInA()
        let r16 = e.setUnavailable(.permissionDenied)
        #expect(r16 == [.revoke])
        #expect(e.state == .unavailable(.permissionDenied))
        _ = e.setUnavailable(nil)
        #expect(e.state == .outside)
        _ = e.ingest(fix(50, 50, at: 30))
        #expect(e.state == .checking(slug: "a"))
    }

    @Test func pauseAndSignOutRevoke() {
        var (e, _) = participatingInA()
        let r17 = e.setUnavailable(.matchingPaused)
        #expect(r17 == [.revoke])
        var (f, _) = participatingInA()
        let r18 = f.setUnavailable(.signedOut)
        #expect(r18 == [.revoke])
        var (g, _) = participatingInA()
        let r19 = g.setUnavailable(.approximateLocation)
        #expect(r19 == [.revoke])
    }

    @Test func leaseLossRequiresFreshConfirmation() {
        var (e, visit) = participatingInA()
        let r20 = e.leaseLost()
        #expect(r20 == [.promptConsent(slug: "a", visit: visit)])
        #expect(e.state == .detected(slug: "a", visit: visit))
        #expect(e.evidence(now: t0.addingTimeInterval(7)) == nil)
    }

    @Test func boundaryChangeEndsTheVisit() {
        var (e, _) = participatingInA()
        let r21 = e.updateZones([zone("a", [square(0, 0, 100, 100)], version: 2), zoneB])
        #expect(r21 == [.revoke])
        #expect(e.state == .outside)
        var (f, _) = participatingInA()
        let r22 = f.updateZones([zoneA, zoneB])
        #expect(r22.isEmpty, "an unchanged list changes nothing")
        let r23 = f.updateZones([zoneB])
        #expect(r23 == [.revoke], "a removed space ends the visit")
    }

    // MARK: Evidence

    @Test func evidenceFreshnessRules() {
        var (e, _) = participatingInA()          // last qualifying fix at t = 6 s, 5 m accuracy, centre of A
        let fresh = e.evidence(now: t0.addingTimeInterval(16))
        #expect(fresh?.stationary == false && fresh?.fixAge == 10)
        #expect(e.evidence(now: t0.addingTimeInterval(22)) == nil, "moving fix older than 15 s is not evidence")
        _ = e.tick(now: t0.addingTimeInterval(22))
        #expect(e.state.hasConsent && e.evidence(now: t0.addingTimeInterval(22)) == nil)
        guard case .unverified = e.state else { Issue.record("stale evidence must demote to unverified"); return }
    }

    @Test func stationaryMayReciteADeepFixForFiveMinutes() {
        var (e, _) = participatingInA()
        e.setStationary(true)
        let reused = e.evidence(now: t0.addingTimeInterval(6 + 120))
        #expect(reused?.stationary == true)
        #expect(e.evidence(now: t0.addingTimeInterval(6 + 301)) == nil, "never longer than 5 minutes")
        e.setStationary(false)
        #expect(e.evidence(now: t0.addingTimeInterval(6 + 120)) == nil, "only while Core Location says stationary")
    }

    @Test func stationaryReuseNeedsDepth() {
        var (e, visit) = detectedInA()
        _ = e.consent(visit: visit)
        _ = e.ingest(fix(20, 50, at: 10, accuracy: 5))  // 20 m from the edge; depth needs ≥ 2 × (5 + 5) = 20 → borderline OK
        _ = e.ingest(fix(15, 50, at: 16, accuracy: 5))  // 15 m from the edge: inside, but too shallow to re-cite
        e.setStationary(true)
        #expect(e.evidence(now: t0.addingTimeInterval(16 + 60)) == nil)
    }

    @Test func evidenceCarriesNoCoordinates() throws {
        let (e, _) = participatingInA()
        let ev = try #require(e.evidence(now: t0.addingTimeInterval(8)))
        #expect(Set(ev.json.keys) == ["fix_ts_ms", "fix_age_ms", "horizontal_accuracy_m", "stationary"])
        let opening = try #require(e.openingEvidence(now: t0.addingTimeInterval(8)))
        #expect(!opening.stationary)
        #expect(e.openingEvidence(now: t0.addingTimeInterval(30)) == nil, "opening needs a fix ≤ 15 s old")
    }
}

struct SpaceZoneTests {
    @Test func bundledZonesAreValidDraftsAndWellSeparated() throws {
        let zones = SpaceZoneCatalog.bundled()
        #expect(zones.map(\.slug) == ["upc-alumni-park-tommy-trojan", "upc-mccarthy-quad", "usc-village-great-lawn"])
        for z in zones {
            #expect(z.validationStatus == .draft, "\(z.slug) has not been walked; it must stay a draft")
            #expect(!z.isUsable(allowDrafts: false), "drafts are unusable without allowDrafts")
            for ring in z.shape.rings { #expect(ring.count >= 4 && ring.first == ring.last) }
        }
        for (i, a) in zones.enumerated() {
            for b in zones[(i + 1)...] {
                #expect(a.shape.minimumDistance(to: b.shape) >= 30, "\(a.slug) and \(b.slug) must be ≥ 30 m apart")
            }
        }
        let center = try #require(zones.first { $0.slug == "upc-alumni-park-tommy-trojan" })
        #expect(center.shape.rings.count == 2, "Alumni Park and Hahn Plaza are one zone")
    }

    @Test func rejectsMalformedGeometry() {
        let open = #"[{"slug":"x-y-z","name":"X","boundary":{"type":"Polygon","coordinates":[[[0,0],[0,1],[1,1],[1,0]]]},"boundary_version":1,"validation_status":"draft","enabled":true}]"#
        #expect(throws: (any Error).self) { try SpaceZoneCatalog.decode(Data(open.utf8)) }
        let point = #"[{"slug":"x-y-z","name":"X","boundary":{"type":"Point","coordinates":[0,0]},"boundary_version":1,"validation_status":"draft","enabled":true}]"#
        #expect(throws: (any Error).self) { try SpaceZoneCatalog.decode(Data(point.utf8)) }
    }
}
