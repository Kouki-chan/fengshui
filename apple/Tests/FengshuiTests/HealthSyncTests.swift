import FengshuiKit
import GRDB
import XCTest
@testable import Fengshui

/// Gate: backfill/incremental with the fake store — batching, resume after interruption,
/// anchors, deletions (spec §14.2 Phase 1).
final class HealthSyncTests: XCTestCase {
    let hr = HealthTypeCatalog.info("HKQuantityTypeIdentifierHeartRate")!

    func testBatchingWritesOnePagePerTransactionAndSavesAnchor() async throws {
        let db = try AppDatabase.temporary("batch")
        let store = FakeHealthStore(samples: (0..<1050).map { sample($0) })
        let sync = HealthSync(db: db, store: store, batchSize: 100)
        let n = try await sync.sync(hr)
        XCTAssertEqual(n, 1050)
        XCTAssertEqual(store.fetchCount, 11)   // 10 full pages + 1 partial
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM processed_samples WHERE label = 'heart_rate'"), 1050)
        let anchor = try await db.writer.read { try Data.fetchOne($0, sql: "SELECT anchor FROM sync_state") }
        XCTAssertEqual(anchor.map { String(decoding: $0, as: UTF8.self) }, "1050")
        XCTAssertEqual(try db.count("SELECT backfill_done FROM sync_state"), 1)
        XCTAssertEqual(try db.count("SELECT minute_id FROM processed_samples WHERE hk_uuid LIKE '%000000000000'"),
                       Int(MinuteID.from(1_792_000_000)))
    }

    func testResumesAfterInterruptionWithoutDuplicates() async throws {
        let db = try AppDatabase.temporary("resume")
        let store = FakeHealthStore(samples: (0..<1000).map { sample($0) })
        store.failOnFetchNumber = 4
        let sync = HealthSync(db: db, store: store, batchSize: 100)
        do { _ = try await sync.sync(hr); XCTFail("expected interruption") } catch {}
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM processed_samples"), 300)
        XCTAssertEqual(try db.count("SELECT backfill_done FROM sync_state"), 0)
        store.failOnFetchNumber = nil
        _ = try await sync.sync(hr)
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM processed_samples"), 1000)
        XCTAssertEqual(try db.count("SELECT COUNT(DISTINCT hk_uuid) FROM processed_samples"), 1000)
        // Resumed at page 4 (pages 4–10) plus one empty page that ends history;
        // pages 1–3 were not fetched again.
        XCTAssertEqual(store.fetchCount, 4 + 8)
    }

    func testIncrementalOnlyFetchesNewAndHandlesDeletions() async throws {
        let db = try AppDatabase.temporary("incr")
        let store = FakeHealthStore(samples: (0..<50).map { sample($0) })
        let sync = HealthSync(db: db, store: store, batchSize: 100)
        _ = try await sync.sync(hr)
        store.add((50..<60).map { sample($0) })
        store.delete(uuid: sample(3).uuid, type: hr.identifier)
        let n = try await sync.sync(hr)
        XCTAssertEqual(n, 10)
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM processed_samples"), 60)
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM processed_samples WHERE deleted = 1"), 1)
        XCTAssertEqual(try db.count("SELECT deleted FROM processed_samples WHERE hk_uuid = '\(sample(3).uuid)'"), 1)
        // Nothing new → nothing written, anchor unchanged.
        let again = try await sync.sync(hr)
        XCTAssertEqual(again, 0)
    }

    func testBackgroundDeliveryRegistersSpecTypesAndSyncsOnWake() async throws {
        let db = try AppDatabase.temporary("bg")
        let store = FakeHealthStore()
        let sync = HealthSync(db: db, store: store)
        let log = EventLog()
        let triggered = Box()
        let bg = BackgroundDelivery(sync: sync, store: store, log: log) { trig in await triggered.add(trig) }
        await bg.register()
        XCTAssertEqual(store.backgroundDeliveryEnabled, Set(HealthTypeCatalog.backgroundDelivery))
        store.add([sample(1)])
        await store.fireObservers(hr.identifier)
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM processed_samples"), 1)
        let t = await triggered.items
        XCTAssertEqual(t, ["healthkit:heart_rate"])
        // Fallback path (launch / BGAppRefresh) syncs everything too.
        store.add([sample(2)])
        await bg.syncNow(trigger: "foreground")
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM processed_samples"), 2)
    }

    func testWorkoutRoutesAndCharacteristics() async throws {
        let db = try AppDatabase.temporary("routes")
        let sc = try Scenario.load("typical_week", bundle: Bundle(for: Self.self))
        let store = FakeHealthStore(scenario: sc)
        let sync = HealthSync(db: db, store: store)
        _ = try await sync.syncAll()
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM processed_samples WHERE label = 'workout'"), sc.workouts.count)
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM processed_route_points"),
                       sc.workouts.reduce(0) { $0 + $1.route.count })
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM processed_samples"), sc.samples.count + sc.workouts.count)
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM characteristics WHERE key = 'date_of_birth'"), 1)
        let done = try await sync.backfillDone()
        XCTAssertTrue(done)
    }

    func testExportRowsAreAdoptedNotDuplicated() async throws {
        let db = try AppDatabase.temporary("adopt")
        // An export row as written by scripts/import_health_export.py.
        let real = sample(7, value: 64.5)
        try await db.writer.write { d in
            try d.execute(sql: """
                INSERT INTO processed_samples (hk_uuid, hk_type, label, value, unit, start_ts, end_ts, minute_id,
                  source_name, inserted_at) VALUES ('export:abc', ?, 'heart_rate', 64.5, 'count/min', ?, ?, ?, ?, 0)
                """, arguments: [real.typeIdentifier, real.start.rounded(), real.end.rounded(),
                                 MinuteID.from(real.start), real.sourceName])
        }
        let store = FakeHealthStore(samples: [real, sample(8)])
        _ = try await HealthSync(db: db, store: store).sync(hr)
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM processed_samples"), 2)
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM processed_samples WHERE hk_uuid = '\(real.uuid)'"), 1)
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM processed_samples WHERE hk_uuid LIKE 'export:%'"), 0)
    }

    func testScenarioFileMatchesPythonGenerator() throws {
        // Same file the Python tests read; spot-check structure.
        let sc = try Scenario.load("typical_week", bundle: Bundle(for: Self.self))
        XCTAssertEqual(sc.tz, "America/New_York")
        XCTAssertGreaterThan(sc.samples.count, 10_000)
        XCTAssertTrue(sc.samples.allSatisfy { $0.start <= sc.now })
        XCTAssertEqual(sc.places.map(\.kind), ["home", "work"])
    }
}

extension HealthSyncTests {
    /// A type HealthKit refuses (e.g. not authorized) is skipped; the backfill continues.
    func testBackfillContinuesPastFailingType() async throws {
        let db = try AppDatabase.temporary("skip")
        let store = FailingTypeStore(samples: (0..<20).map { sample($0) })
        let sync = HealthSync(db: db, store: store)
        let n = try await sync.syncAll()
        XCTAssertEqual(n, 20)
        let failures = await sync.lastFailures
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].hasPrefix("workout"))
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM sync_state WHERE hk_type = 'HKWorkoutTypeIdentifier'"), 0)
    }
}

final class FailingTypeStore: FakeHealthStore, @unchecked Sendable {
    override func fetch(_ type: HealthTypeInfo, anchor: Data?, limit: Int) async throws -> HealthPage {
        if type.kind == .workout {
            throw NSError(domain: "com.apple.healthkit", code: 5, userInfo: [NSLocalizedDescriptionKey: "Authorization not determined"])
        }
        return try await super.fetch(type, anchor: anchor, limit: limit)
    }
}

actor Box {
    var items: [String] = []
    func add(_ s: String) { items.append(s) }
}
