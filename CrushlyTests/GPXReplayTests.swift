import Foundation
import Testing
@testable import Crushly

/// Replays the simulator routes in Config/Locations through the real engine and the bundled DRAFT zones, so the
/// fixtures used for manual simulator testing are themselves verified. Accuracy is a synthetic 5 m; real devices
/// on campus will be noisier, which is what field validation is for.
struct GPXReplayTests {
    private static let locationsDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Config/Locations")

    private func samples(_ name: String) throws -> [LocationSample] {
        let text = try String(contentsOf: Self.locationsDir.appendingPathComponent("\(name).gpx"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"<wpt lat="([-0-9.]+)" lon="([-0-9.]+)"><time>([^<]+)</time>"#)
        let iso = ISO8601DateFormatter()
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            func group(_ i: Int) -> String { String(text[Range(m.range(at: i), in: text)!]) }
            guard let lat = Double(group(1)), let lon = Double(group(2)), let t = iso.date(from: group(3)) else { return nil }
            return LocationSample(coordinate: GeoPoint(latitude: lat, longitude: lon), horizontalAccuracy: 5, timestamp: t)
        }
    }

    /// Runs a route, consenting to every prompt when `consent` is true. Returns every effect in order.
    private func replay(_ name: String, consent: Bool) throws -> (MembershipEngine, [MembershipEffect]) {
        var engine = MembershipEngine(zones: SpaceZoneCatalog.bundled())
        _ = engine.setUnavailable(nil)
        var effects: [MembershipEffect] = []
        let route = try samples(name)
        #expect(route.count > 10, "route \(name) parsed")
        for s in route {
            let e = engine.ingest(s)
            effects += e
            for case .promptConsent(_, let visit) in e where consent { _ = engine.consent(visit: visit) }
        }
        return (engine, effects)
    }

    @Test func walkingIntoMcCarthyQuadPromptsOnce() throws {
        let (engine, effects) = try replay("EnterMcCarthyQuad", consent: false)
        #expect(effects.count == 1)
        #expect(engine.state.slug == "upc-mccarthy-quad")
        guard case .detected = engine.state else { Issue.record("expected a pending choice"); return }
    }

    @Test func alumniParkToMcCarthyQuadRevokesThenAsksAgain() throws {
        let (engine, effects) = try replay("AlumniParkToMcCarthyQuad", consent: true)
        let slugs = effects.compactMap { if case .promptConsent(let s, _) = $0 { s } else { nil } }
        #expect(slugs == ["upc-alumni-park-tommy-trojan", "upc-mccarthy-quad"])
        let revokeIndex = try #require(effects.firstIndex(of: .revoke))
        let secondPrompt = try #require(effects.lastIndex { if case .promptConsent = $0 { true } else { false } })
        #expect(revokeIndex < secondPrompt, "the old space is revoked before the new one is offered")
        #expect(engine.state.slug == "upc-mccarthy-quad" && engine.state.hasConsent)
    }

    @Test func crossingTheHahnPlazaSeamStaysInside() throws {
        let (engine, effects) = try replay("HahnPlazaSeam", consent: true)
        #expect(!effects.contains(.revoke), "Alumni Park and Hahn Plaza are one zone")
        #expect(engine.state.slug == "upc-alumni-park-tommy-trojan" && engine.state.hasConsent)
    }

    @Test func leavingTheGreatLawnRevokes() throws {
        let (engine, effects) = try replay("LeaveGreatLawn", consent: true)
        #expect(effects.filter { $0 == .revoke }.count == 1)
        #expect(engine.state == .outside)
    }
}
