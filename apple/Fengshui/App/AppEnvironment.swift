import FengshuiKit
import Foundation

/// Dependency container. Real Apple frameworks in normal runs; fakes loaded with a
/// named scenario when launched with `-FengshuiTestMode <scenario>` (spec §14.1),
/// so UI tests never hit permission dialogs.
final class AppEnvironment: Sendable {
    let db: AppDatabase
    let clock: Clock
    let health: HealthStore
    let healthSync: HealthSync
    let delivery: BackgroundDelivery
    let location: LocationProvider
    let places: PlaceService
    let motion: MotionImporter
    let log: EventLog
    let testScenario: String?
    let timeZone: TimeZone

    init(db: AppDatabase, clock: Clock, health: HealthStore, location: LocationProvider, motion: MotionHistory,
         testScenario: String?, timeZone: TimeZone) {
        self.db = db
        self.clock = clock
        self.health = health
        self.location = location
        self.testScenario = testScenario
        self.timeZone = timeZone
        let log = EventLog(clock: { [clock] in clock.now })
        self.log = log
        let sync = HealthSync(db: db, store: health, clock: clock)
        healthSync = sync
        let motionImporter = MotionImporter(db: db, history: motion, clock: clock)
        self.motion = motionImporter
        places = PlaceService(db: db, location: location, log: log, clock: clock)
        delivery = BackgroundDelivery(sync: sync, store: health, log: log) { trigger in
            // Every sync also pulls iPhone motion history (spec §6.3).
            do {
                let n = try await motionImporter.importNew()
                log.add("motion", "\(trigger) +\(n)")
            } catch {
                log.add("motion_error", "\(error)")
            }
            // Engine trigger is wired in Phase 4 (EngineRunner).
        }
    }

    var isTestMode: Bool { testScenario != nil }

    /// Builds the environment for this process from its launch arguments.
    static func make(arguments: [String] = ProcessInfo.processInfo.arguments) throws -> AppEnvironment {
        if let i = arguments.firstIndex(of: "-FengshuiTestMode"), i + 1 < arguments.count {
            let name = arguments[i + 1]
            let scenario = try Scenario.load(name)
            // Fresh DB per launch: UI tests start from a known state.
            let db = try AppDatabase.temporary("testmode-\(name)")
            let home = scenario.places.first { $0.kind == "home" }
            return AppEnvironment(db: db, clock: FixedClock(Date(timeIntervalSince1970: scenario.now)),
                                  health: FakeHealthStore(scenario: scenario),
                                  location: FakeLocationProvider(coordinate: (home?.lat ?? 40.1, home?.lon ?? -75.2)),
                                  motion: FakeMotionHistory(scenario: scenario), testScenario: name,
                                  timeZone: TimeZone(identifier: scenario.tz) ?? .current)
        }
        return AppEnvironment(db: try AppDatabase(path: AppDatabase.defaultURL().path), clock: SystemClock(),
                              health: HKHealthStoreAdapter(), location: CoreLocationProvider(),
                              motion: CoreMotionHistory(), testScenario: nil, timeZone: .current)
    }
}
