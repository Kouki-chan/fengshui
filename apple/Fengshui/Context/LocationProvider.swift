import CoreLocation
import Foundation

/// A named place's geofence (spec §6.2).
struct PlaceRegion: Sendable, Hashable {
    var placeID: Int64
    var lat: Double
    var lon: Double
    var radius: Double
    var identifier: String { "place-\(placeID)" }
}

enum LocationEvent: Sendable, Equatable {
    /// CLVisit: arrival-only while ongoing (departure nil), then again with both dates.
    case visit(arrival: Double, departure: Double?, lat: Double, lon: Double, hAccuracy: Double)
    case region(identifier: String, entered: Bool, at: Double)
    case significantChange(lat: Double, lon: Double, at: Double)
}

enum LocationAuthorization: String, Sendable { case notDetermined, whenInUse, always, denied }

/// Significant places only: visit monitoring, significant-change and geofences,
/// never continuous GPS (spec §6.2). Fake in tests and test mode.
protocol LocationProvider: AnyObject, Sendable {
    var authorization: LocationAuthorization { get }
    func requestAlwaysAuthorization() async -> LocationAuthorization
    func currentCoordinate() async throws -> (lat: Double, lon: Double)
    /// Starts visit + significant-change monitoring and geofence event delivery.
    func start(_ handler: @escaping @Sendable (LocationEvent) async -> Void) async
    /// Replaces the monitored geofences with exactly `regions`.
    func setGeofences(_ regions: [PlaceRegion]) async
    func monitoredIdentifiers() async -> Set<String>
}

/// Real implementation: CLLocationManager for visits / significant changes and the
/// iOS 17+ CLMonitor for geofences. CLMonitor relaunches the app on region events
/// as long as a monitor with the same name is re-created at launch.
final class CoreLocationProvider: NSObject, LocationProvider, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    /// Exactly one CLMonitor per name may be open per process; a second open fails ("Monitor
    /// name is not valid" / "already in use"). Every provider goes through this one lazily
    /// created instance, and one events loop forwards to the newest handler.
    private static let monitorLock = NSLock()
    nonisolated(unsafe) private static var monitorTask: Task<CLMonitor, Never>?
    nonisolated(unsafe) private static var eventsStarted = false
    nonisolated(unsafe) private static var regionHandler: (@Sendable (LocationEvent) async -> Void)?
    /// Visits and significant changes come from this provider's own manager.
    private var handler: (@Sendable (LocationEvent) async -> Void)?
    private var authContinuation: CheckedContinuation<LocationAuthorization, Never>?
    private var locationContinuation: CheckedContinuation<(lat: Double, lon: Double), Error>?
    private static let monitorName = "FengshuiPlaces"

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var authorization: LocationAuthorization { Self.map(manager.authorizationStatus) }

    private static func map(_ s: CLAuthorizationStatus) -> LocationAuthorization {
        switch s {
        case .authorizedAlways: .always
        case .authorizedWhenInUse: .whenInUse
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }

    func requestAlwaysAuthorization() async -> LocationAuthorization {
        await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                self.authContinuation = cont
                // iOS asks When-In-Use first, then offers Always on the next request.
                if self.manager.authorizationStatus == .notDetermined {
                    self.manager.requestWhenInUseAuthorization()
                } else {
                    self.manager.requestAlwaysAuthorization()
                }
            }
        }
    }

    func currentCoordinate() async throws -> (lat: Double, lon: Double) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                self.locationContinuation = cont
                self.manager.requestLocation()   // one fix, not continuous updates
            }
        }
    }

    func start(_ handler: @escaping @Sendable (LocationEvent) async -> Void) async {
        self.handler = handler
        Self.monitorLock.withLock { Self.regionHandler = handler }
        await MainActor.run {
            manager.startMonitoringVisits()
            manager.startMonitoringSignificantLocationChanges()
        }
        let m = await sharedMonitor()
        let first = Self.monitorLock.withLock { defer { Self.eventsStarted = true }; return !Self.eventsStarted }
        guard first else { return }
        Task {
            for try await e in await m.events {
                guard let handler = Self.monitorLock.withLock({ Self.regionHandler }) else { continue }
                await handler(.region(identifier: e.identifier, entered: e.state == .satisfied,
                                      at: e.date.timeIntervalSince1970))
            }
        }
    }

    func setGeofences(_ regions: [PlaceRegion]) async {
        let m = await sharedMonitor()
        let wanted = Dictionary(uniqueKeysWithValues: regions.map { ($0.identifier, $0) })
        for id in await m.identifiers where wanted[id] == nil { await m.remove(id) }
        for (id, r) in wanted {
            let cond = CLMonitor.CircularGeographicCondition(
                center: CLLocationCoordinate2D(latitude: r.lat, longitude: r.lon), radius: r.radius)
            await m.add(cond, identifier: id, assuming: .unsatisfied)
        }
    }

    func monitoredIdentifiers() async -> Set<String> {
        Set(await sharedMonitor().identifiers)
    }

    private func sharedMonitor() async -> CLMonitor {
        let task = Self.monitorLock.withLock {
            if let t = Self.monitorTask { return t }
            let t = Task { await CLMonitor(Self.monitorName) }
            Self.monitorTask = t
            return t
        }
        return await task.value
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined, let c = authContinuation else { return }
        authContinuation = nil
        c.resume(returning: Self.map(manager.authorizationStatus))
        if manager.authorizationStatus == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
    }

    func locationManager(_ manager: CLLocationManager, didVisit v: CLVisit) {
        let arrival = v.arrivalDate == .distantPast ? Date() : v.arrivalDate
        let departure = v.departureDate == .distantFuture ? nil : v.departureDate
        let e = LocationEvent.visit(arrival: arrival.timeIntervalSince1970, departure: departure?.timeIntervalSince1970,
                                    lat: v.coordinate.latitude, lon: v.coordinate.longitude,
                                    hAccuracy: v.horizontalAccuracy)
        if let handler { Task { await handler(e) } }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        if let c = locationContinuation {
            locationContinuation = nil
            c.resume(returning: (l.coordinate.latitude, l.coordinate.longitude))
        } else if let handler {
            let e = LocationEvent.significantChange(lat: l.coordinate.latitude, lon: l.coordinate.longitude,
                                                    at: l.timestamp.timeIntervalSince1970)
            Task { await handler(e) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let c = locationContinuation { locationContinuation = nil; c.resume(throwing: error) }
    }
}

/// Test double: records geofences, lets tests push events.
final class FakeLocationProvider: LocationProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var regions: [String: PlaceRegion] = [:]
    private var handler: (@Sendable (LocationEvent) async -> Void)?
    var coordinate: (lat: Double, lon: Double)
    var authorization: LocationAuthorization = .notDetermined
    private(set) var setGeofencesCalls = 0

    init(coordinate: (lat: Double, lon: Double) = (40.1, -75.2)) { self.coordinate = coordinate }

    func requestAlwaysAuthorization() async -> LocationAuthorization {
        authorization = .always
        return .always
    }

    func currentCoordinate() async throws -> (lat: Double, lon: Double) { coordinate }

    func start(_ handler: @escaping @Sendable (LocationEvent) async -> Void) async {
        lock.withLock { self.handler = handler }
    }

    func setGeofences(_ regions: [PlaceRegion]) async {
        lock.withLock {
            setGeofencesCalls += 1
            self.regions = Dictionary(uniqueKeysWithValues: regions.map { ($0.identifier, $0) })
        }
    }

    func monitoredIdentifiers() async -> Set<String> { lock.withLock { Set(regions.keys) } }

    func monitored() -> [PlaceRegion] { lock.withLock { Array(regions.values) } }

    func send(_ e: LocationEvent) async {
        let h = lock.withLock { handler }
        await h?(e)
    }
}
