import CoreLocation
import Foundation

// Thin Core Location wrapper (docs/CAMPUS_SPACES_DESIGN.md §2–3.4). Requires When-In-Use only.
//
// * While the app is open and campus matching is on: iterate CLLocationUpdate.liveUpdates (pauses itself when the
//   device is stationary, so it isn't continuous high-accuracy GPS).
// * While the user is participating: hold a CLBackgroundActivitySession so renewals can continue in the background,
//   with the system's blue location indicator. It's created only in the foreground, at the user's opt-in, and
//   invalidated the moment participation ends.
// * Approximate location: ask for temporary precise access with a purpose string; otherwise report "approximate".
//
// Coordinates go only to the in-memory MembershipEngine. Nothing here logs, stores or transmits them.

nonisolated enum LocationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied            // denied, restricted, or Location Services off
    case approximate       // authorized, reduced accuracy
    case precise           // authorized, full accuracy
}

nonisolated enum LocationEvent: Sendable {
    case sample(LocationSample)
    case stationary(Bool)
    case authorization(LocationAuthorization)
    /// Location temporarily unavailable (no fix possible right now).
    case unavailable
}

@MainActor
protocol LocationProviding: AnyObject {
    var authorization: LocationAuthorization { get }
    /// All location events, delivered on the main actor. One consumer.
    var events: AsyncStream<LocationEvent> { get }
    func requestWhenInUse()
    func requestTemporaryPreciseAccess()
    func startUpdates()
    func stopUpdates()
    func beginBackgroundParticipation()
    func endBackgroundParticipation()
}

@MainActor
final class LocationService: NSObject, LocationProviding {
    /// Info.plist NSLocationTemporaryUsageDescriptionDictionary key.
    static let precisePurposeKey = "CampusMatching"

    private let manager = CLLocationManager()
    private var continuation: AsyncStream<LocationEvent>.Continuation?
    private var updatesTask: Task<Void, Never>?
    private var serviceSession: CLServiceSession?
    private var backgroundSession: CLBackgroundActivitySession?
    private var lastStationary: Bool?

    let events: AsyncStream<LocationEvent>
    private(set) var authorization: LocationAuthorization = .notDetermined

    override init() {
        var c: AsyncStream<LocationEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(32)) { c = $0 }
        super.init()
        continuation = c
        manager.delegate = self
        authorization = Self.map(manager)
    }

    func requestWhenInUse() {
        // A service session declares the goal; Core Location shows the prompt when appropriate.
        if serviceSession == nil { serviceSession = CLServiceSession(authorization: .whenInUse) }
    }

    func requestTemporaryPreciseAccess() {
        serviceSession?.invalidate()
        serviceSession = CLServiceSession(authorization: .whenInUse, fullAccuracyPurposeKey: Self.precisePurposeKey)
    }

    func startUpdates() {
        guard updatesTask == nil else { return }
        requestWhenInUse()
        updatesTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.default) {
                    guard let self, !Task.isCancelled else { break }
                    self.handle(update)
                }
            } catch {
                self?.continuation?.yield(.unavailable)
            }
        }
    }

    func stopUpdates() {
        updatesTask?.cancel()
        updatesTask = nil
        lastStationary = nil
    }

    func beginBackgroundParticipation() {
        guard backgroundSession == nil else { return }
        backgroundSession = CLBackgroundActivitySession()
    }

    func endBackgroundParticipation() {
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    private func handle(_ update: CLLocationUpdate) {
        if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
            setAuthorization(.denied)
            return
        }
        if update.accuracyLimited {
            setAuthorization(.approximate)
            return   // approximate fixes (1–20 km) are never evidence
        }
        if update.stationary != lastStationary {
            lastStationary = update.stationary
            continuation?.yield(.stationary(update.stationary))
        }
        guard let location = update.location else {
            if update.locationUnavailable { continuation?.yield(.unavailable) }
            return
        }
        continuation?.yield(.sample(LocationSample(
            coordinate: GeoPoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: location.timestamp,
            stationary: update.stationary)))
    }

    private func setAuthorization(_ value: LocationAuthorization) {
        guard value != authorization else { return }
        authorization = value
        continuation?.yield(.authorization(value))
    }

    /// Location Services being switched off globally arrives via liveUpdates' `authorizationDeniedGlobally`
    /// (calling `locationServicesEnabled()` here would block the main thread).
    fileprivate static func map(_ manager: CLLocationManager) -> LocationAuthorization {
        switch manager.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        case .authorizedWhenInUse, .authorizedAlways:
            return manager.accuracyAuthorization == .fullAccuracy ? .precise : .approximate
        @unknown default: return .denied
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.setAuthorization(Self.map(self.manager))
        }
    }
}
