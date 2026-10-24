import Foundation

/// In-memory HealthKit stand-in for unit tests and `-FengshuiTestMode` (spec §14.1).
/// Anchors are the integer index of the next change in an append-only change log,
/// which mimics HKQueryAnchor: samples added and deleted later show up in later pages.
final class FakeHealthStore: HealthStore, @unchecked Sendable {
    enum Change { case add(HealthSample), delete(String) }

    private let lock = NSLock()
    private var log: [String: [Change]] = [:]
    private var routes: [String: [RoutePoint]] = [:]
    private var observers: [String: [@Sendable () async -> Void]] = [:]
    private(set) var authorizationRequested: [HealthTypeInfo] = []
    private(set) var backgroundDeliveryEnabled: Set<String> = []
    var chars: [String: String] = [:]
    /// Throw on the Nth fetch call (simulates interruption mid-backfill).
    var failOnFetchNumber: Int?
    private(set) var fetchCount = 0
    var isAvailable = true

    init(samples: [HealthSample] = []) {
        add(samples)
    }

    convenience init(scenario: Scenario) {
        var all = scenario.samples
        for w in scenario.workouts {
            let meta = try? JSONSerialization.data(withJSONObject: ["energy_kcal": w.energy_kcal, "distance_m": w.distance_m],
                                                   options: .sortedKeys)
            all.append(HealthSample(uuid: w.uuid, typeIdentifier: "HKWorkoutTypeIdentifier", label: "workout",
                                    value: w.end - w.start, valueText: w.activity, unit: "s", start: w.start, end: w.end,
                                    sourceName: w.source, sourceBundle: nil, device: nil,
                                    metadataJSON: meta.flatMap { String(data: $0, encoding: .utf8) }))
        }
        self.init(samples: all)
        chars = scenario.characteristics
        for w in scenario.workouts {
            routes[w.uuid] = w.route.map {
                RoutePoint(ts: $0[0], lat: $0[1], lon: $0[2], altitude: $0[3], speed: $0[4], horizontalAccuracy: $0[5])
            }
        }
    }

    func add(_ samples: [HealthSample]) {
        lock.withLock { for s in samples { log[s.typeIdentifier, default: []].append(.add(s)) } }
    }

    func delete(uuid: String, type: String) {
        lock.withLock { log[type, default: []].append(.delete(uuid)) }
    }

    /// Simulates a HealthKit background-delivery wake for `type`.
    func fireObservers(_ type: String) async {
        let obs = lock.withLock { observers[type] ?? [] }
        for o in obs { await o() }
    }

    func requestAuthorization(read types: [HealthTypeInfo]) async throws {
        lock.withLock { authorizationRequested = types }
    }

    func supportedTypes(_ types: [HealthTypeInfo]) -> [HealthTypeInfo] { types }

    func fetch(_ type: HealthTypeInfo, anchor: Data?, limit: Int) async throws -> HealthPage {
        try lock.withLock { try page(type, anchor: anchor, limit: limit) }
    }

    private func page(_ type: HealthTypeInfo, anchor: Data?, limit: Int) throws -> HealthPage {
        fetchCount += 1
        if let n = failOnFetchNumber, fetchCount == n {
            throw CocoaError(.userCancelled)
        }
        let changes = log[type.identifier] ?? []
        let from = anchor.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let to = min(changes.count, from + limit)
        var samples: [HealthSample] = []
        var deleted: [String] = []
        for c in changes[from..<to] {
            switch c {
            case .add(let s): samples.append(s)
            case .delete(let u): deleted.append(u)
            }
        }
        return HealthPage(samples: samples, deletedUUIDs: deleted, anchor: Data(String(to).utf8),
                          hasMore: to - from >= limit)
    }

    func routePoints(workoutUUID: String) async throws -> [RoutePoint] {
        lock.withLock { routes[workoutUUID] ?? [] }
    }

    func characteristics() async -> [String: String] { chars }

    func preferredUnits(for types: [HealthTypeInfo]) async -> [String: String] {
        Dictionary(types.compactMap { t in HealthTypeCatalog.unit(for: t).map { (t.identifier, $0) } },
                   uniquingKeysWith: { a, _ in a })
    }

    func observe(_ type: HealthTypeInfo, onChange: @escaping @Sendable () async -> Void) async throws {
        lock.withLock {
            observers[type.identifier, default: []].append(onChange)
            backgroundDeliveryEnabled.insert(type.identifier)
        }
    }
}
