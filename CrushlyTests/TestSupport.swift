import Foundation
@testable import Crushly

/// A location source the test drives by hand (no timers), so AppState tests are deterministic.
@MainActor
final class TestLocationProvider: LocationProviding {
    let events: AsyncStream<LocationEvent>
    private let continuation: AsyncStream<LocationEvent>.Continuation
    var authorization: LocationAuthorization
    private(set) var updating = false
    private(set) var backgroundActive = false
    private(set) var whenInUseRequests = 0

    init(authorization: LocationAuthorization = .precise) {
        self.authorization = authorization
        (events, continuation) = AsyncStream.makeStream()
    }

    func requestWhenInUse() { whenInUseRequests += 1 }
    func requestTemporaryPreciseAccess() {}
    func startUpdates() { updating = true }
    func stopUpdates() { updating = false }
    func beginBackgroundParticipation() { backgroundActive = true }
    func endBackgroundParticipation() { backgroundActive = false }
}

@MainActor
enum TestWorld {
    static let zones = SpaceZoneCatalog.bundled()

    static func point(in slug: String) -> GeoPoint {
        SimulatedLocationProvider.interiorPoint(of: zones.first { $0.slug == slug }!.shape)
    }

    static func sample(_ slug: String?, secondsAgo: TimeInterval = 0, accuracy: Double = 8) -> LocationSample {
        LocationSample(coordinate: slug.map(point(in:)) ?? SimulatedLocationProvider.outsidePoint,
                       horizontalAccuracy: accuracy, timestamp: Date().addingTimeInterval(-secondsAgo))
    }

    static func demo(seeded: Bool = true, rateLimits: Bool = false) -> DemoBackend {
        DemoBackend(options: .init(seededAccount: seeded, receiptDelay: 0, replyDelay: 0, latency: .zero,
                                   enforceRateLimits: rateLimits))
    }

    static func state(_ demo: DemoBackend, location given: TestLocationProvider? = nil) -> AppState {
        let location = given ?? TestLocationProvider()
        UserDefaults.standard.removeObject(forKey: "crushly.campusMatchingOn")
        UserDefaults.standard.removeObject(forKey: "crushly.revealed")
        UserDefaults.standard.removeObject(forKey: "crushly.notificationPrimerDismissed")
        return AppState(config: AppConfig(environment: .demo), backend: demo, demo: demo, location: location, timing: .manual,
                        messageCache: MessageCache(root: FileManager.default.temporaryDirectory
                            .appendingPathComponent("crushly-tests-\(UUID().uuidString)", isDirectory: true)))
    }

    /// Fresh, moving evidence (device-reported; the demo, like the server, checks plausibility only).
    static func evidence(_ offset: TimeInterval = 0, age: TimeInterval = 1, accuracy: Double = 10, stationary: Bool = false) -> LocationEvidence {
        LocationEvidence(fixTimestamp: Date().addingTimeInterval(offset), fixAge: age, horizontalAccuracy: accuracy, stationary: stationary)
    }
}

extension AppState {
    /// Signed in, opted in at McCarthy Quad, and matched with Mina (who already expressed interest).
    static func matchedWithMina() async throws -> (AppState, DemoBackend, UUID) {
        let demo = TestWorld.demo()
        let state = TestWorld.state(demo)
        await state.bootstrap()
        await state.turnOnCampusMatching()
        await state.walkInto(DemoWorld.mcCarthyQuad)
        await state.openToMatching()
        guard let mina = state.candidates.first(where: { $0.firstName == "Mina" }),
              case .matched(let id, _) = try await state.expressInterest(in: mina) else {
            throw CrushlyError.unknown("no match with Mina")
        }
        state.revealMatch = nil
        return (state, demo, id)
    }

    /// Two stable fixes inside the space: the engine detects it and asks for consent.
    func walkInto(_ slug: String) async {
        await ingest(.sample(TestWorld.sample(slug, secondsAgo: 6)))
        await ingest(.sample(TestWorld.sample(slug)))
    }
}
