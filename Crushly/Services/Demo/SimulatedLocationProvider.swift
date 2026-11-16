import Foundation

/// DEV FIXTURE — a fake location source for demo mode only. AppState.make pairs it exclusively with DemoBackend,
/// which is in-memory and can't reach the server, so a simulated position can never open a real session.
/// Live mode always uses `LocationService` (Core Location).
@MainActor
final class SimulatedLocationProvider: LocationProviding {
    enum Place: Hashable {
        case outside
        case zone(String)
    }

    let events: AsyncStream<LocationEvent>
    private let continuation: AsyncStream<LocationEvent>.Continuation
    private(set) var authorization: LocationAuthorization
    private(set) var place: Place
    private(set) var isUpdating = false
    private(set) var backgroundActive = false
    private var timer: Task<Void, Never>?
    private let zones: [SpaceZone]
    var accuracy: Double = 8
    var interval: Duration = .seconds(4)

    /// A point well away from every bundled zone (south of campus).
    static let outsidePoint = GeoPoint(latitude: 34.0150, longitude: -118.2900)

    init(zones: [SpaceZone], place: Place = .outside, authorization: LocationAuthorization = .notDetermined) {
        self.zones = zones
        self.place = place
        self.authorization = authorization
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
    }

    /// Demo launch arguments: `-CrushlyDemoLocation <slug|outside>`, `-CrushlyDemoLocationAuth <precise|approximate|denied|notDetermined>`.
    static func fromLaunchArguments(_ args: [String], zones: [SpaceZone]) -> SimulatedLocationProvider {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let place: Place = value("-CrushlyDemoLocation").map { $0 == "outside" ? .outside : .zone($0) } ?? .outside
        let auth: LocationAuthorization = switch value("-CrushlyDemoLocationAuth") {
        case "precise": .precise
        case "approximate": .approximate
        case "denied": .denied
        default: .notDetermined
        }
        return SimulatedLocationProvider(zones: zones, place: place, authorization: auth)
    }

    // MARK: Demo controls

    func move(to place: Place) {
        self.place = place
        if isUpdating { emit() }
    }

    func setAuthorization(_ value: LocationAuthorization) {
        guard value != authorization else { return }
        authorization = value
        continuation.yield(.authorization(value))
    }

    // MARK: LocationProviding

    func requestWhenInUse() {
        if authorization == .notDetermined { setAuthorization(.precise) }
    }

    func requestTemporaryPreciseAccess() {
        if authorization == .approximate { setAuthorization(.precise) }
    }

    func startUpdates() {
        guard !isUpdating else { return }
        requestWhenInUse()
        isUpdating = true
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.emit()
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    func stopUpdates() {
        timer?.cancel()
        timer = nil
        isUpdating = false
    }

    func beginBackgroundParticipation() { backgroundActive = true }
    func endBackgroundParticipation() { backgroundActive = false }

    private func emit() {
        guard authorization == .precise else { return }
        continuation.yield(.sample(LocationSample(coordinate: coordinate, horizontalAccuracy: accuracy, timestamp: Date())))
    }

    var coordinate: GeoPoint {
        guard case .zone(let slug) = place, let zone = zones.first(where: { $0.slug == slug }) else { return Self.outsidePoint }
        return Self.interiorPoint(of: zone.shape)
    }

    /// The point of the zone's first ring that is deepest inside it (searched on a coarse grid). Deterministic.
    static func interiorPoint(of shape: ZoneShape) -> GeoPoint {
        guard let ring = shape.rings.first, let origin = ring.first else { return outsidePoint }
        let projection = LocalProjection(origin: origin)
        let pts = ring.map(projection.project)
        let xs = pts.map(\.x), ys = pts.map(\.y)
        var best = (point: origin, depth: -Double.infinity)
        let steps = 24
        for i in 0...steps {
            for j in 0...steps {
                let v = ZoneShape.Vec2(x: xs.min()! + (xs.max()! - xs.min()!) * Double(i) / Double(steps),
                                       y: ys.min()! + (ys.max()! - ys.min()!) * Double(j) / Double(steps))
                guard ZoneShape.contains(pts, v) else { continue }
                let depth = ZoneShape.distanceToBoundary(pts, v)
                if depth > best.depth { best = (projection.unproject(v), depth) }
            }
        }
        return best.point
    }
}
