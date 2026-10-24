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
    let log: EventLog
    let testScenario: String?
    let timeZone: TimeZone

    init(db: AppDatabase, clock: Clock, health: HealthStore, testScenario: String?, timeZone: TimeZone) {
        self.db = db
        self.clock = clock
        self.health = health
        self.testScenario = testScenario
        self.timeZone = timeZone
        let log = EventLog(clock: { [clock] in clock.now })
        self.log = log
        let sync = HealthSync(db: db, store: health, clock: clock)
        healthSync = sync
        delivery = BackgroundDelivery(sync: sync, store: health, log: log) { _ in
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
            return AppEnvironment(db: db, clock: FixedClock(Date(timeIntervalSince1970: scenario.now)),
                                  health: FakeHealthStore(scenario: scenario), testScenario: name,
                                  timeZone: TimeZone(identifier: scenario.tz) ?? .current)
        }
        return AppEnvironment(db: try AppDatabase(path: AppDatabase.defaultURL().path), clock: SystemClock(),
                              health: HKHealthStoreAdapter(), testScenario: nil, timeZone: .current)
    }
}
