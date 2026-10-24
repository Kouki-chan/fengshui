import Foundation

/// A HealthKit sample converted to Fengshui's row shape (spec §5 processed_samples).
struct HealthSample: Sendable, Equatable {
    var uuid: String
    var typeIdentifier: String
    var label: String
    var value: Double?
    var valueText: String?
    var unit: String?
    var start: Double
    var end: Double
    var sourceName: String?
    var sourceBundle: String?
    var device: String?
    var metadataJSON: String?
}

struct RoutePoint: Sendable, Equatable {
    var ts: Double
    var lat: Double
    var lon: Double
    var altitude: Double?
    var speed: Double?
    var horizontalAccuracy: Double?
}

/// One page of an anchored query: new samples, deleted UUIDs, and the anchor to resume from.
struct HealthPage: Sendable {
    var samples: [HealthSample]
    var deletedUUIDs: [String]
    var anchor: Data?
    /// false when the query returned fewer than `limit` results (history exhausted).
    var hasMore: Bool
}

enum HealthAuthorizationState: Sendable, Equatable {
    case notDetermined, requested, unavailable
}

/// Everything Fengshui needs from HealthKit, behind a protocol so tests and
/// `-FengshuiTestMode` use `FakeHealthStore` (spec §14.1).
protocol HealthStore: Sendable {
    var isAvailable: Bool { get }

    /// Requests read access for `types` and share access for workouts.
    func requestAuthorization(read types: [HealthTypeInfo]) async throws

    /// Types that resolve to an HKObjectType on this OS (the rest are logged and skipped).
    func supportedTypes(_ types: [HealthTypeInfo]) -> [HealthTypeInfo]

    /// Anchored query page (HKAnchoredObjectQuery with a limit); nil anchor = from the beginning.
    func fetch(_ type: HealthTypeInfo, anchor: Data?, limit: Int) async throws -> HealthPage

    func routePoints(workoutUUID: String) async throws -> [RoutePoint]

    func characteristics() async -> [String: String]

    func preferredUnits(for types: [HealthTypeInfo]) async -> [String: String]

    /// Observer query + background delivery. `onChange` runs on each HealthKit wake and
    /// must call its completion when the sync is done.
    func observe(_ type: HealthTypeInfo, onChange: @escaping @Sendable () async -> Void) async throws
}
