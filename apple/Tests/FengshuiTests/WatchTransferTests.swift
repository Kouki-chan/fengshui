import FengshuiKit
import GRDB
import XCTest
@testable import Fengshui

/// Gate (Phase 3): transfer → phone import → acknowledgment → watch deletes, over the
/// in-process fake transport; phone import is idempotent.
final class WatchTransferTests: XCTestCase {
    /// Delivers each file to the phone importer right away, like WCSession would.
    final class LoopbackTransport: WatchFileTransport, @unchecked Sendable {
        var delivered: [(URL, [String: Any])] = []
        func send(file: URL, metadata: [String: Any]) { delivered.append((file, metadata)) }
    }

    final class Accel: AccelerometerRecorder, @unchecked Sendable {
        var isAvailable = true
        func arm(duration: TimeInterval) {}
        func samples(from: Double, to: Double) async throws -> [SensorSample] {
            var out: [SensorSample] = []
            let first = (from * 50).rounded(.up)
            var i = 0.0
            while (first + i) / 50 < to {
                let t = (first + i) / 50
                out.append(SensorSample(ts: t, values: [0.1 * sin(2 * .pi * 1.8 * t), 0.02, -1 + 0.3 * sin(2 * .pi * 1.8 * t)]))
                i += 1
            }
            return out
        }
    }

    struct NoSnapshots: SnapshotSensors {
        func capture(seconds: Double, rateHz: Double, sensors: Set<Sensor>) async throws -> [Sensor: [SensorSample]] { [:] }
    }

    struct Battery: BatteryState { var level = 1.0; var isLowPowerMode = false }

    let t0 = 1_792_843_200.0

    func testTransferImportAckDelete() async throws {
        let db = try AppDatabase.temporary("transfer")
        let clock = FixedClock(Date(timeIntervalSince1970: t0))
        let transport = LoopbackTransport()
        let kv = MemoryKeyValueStore()
        kv.set(t0 - 7200, "last_harvested")
        let outbox = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID())")
        var prefs = RecordingPreferences()
        prefs.gyroscope = false; prefs.barometer = false; prefs.compass = false
        let watch = WatchRecorder(accel: Accel(), snapshots: NoSnapshots(), battery: Battery(), transport: transport,
                                  state: kv, clock: clock, outboxDir: outbox, prefs: prefs)
        let report = await watch.wake(deadline: clock.now.addingTimeInterval(30))
        XCTAssertEqual(report.filesSent.count, 2)
        XCTAssertEqual(watch.outbox.pending.count, 2)

        let phone = WatchImporter(db: db, clock: clock)
        let link = FakeWatchLink()
        for (url, meta) in transport.delivered {
            XCTAssertEqual(meta["encoding"] as? String, "fsr1-i16-delta-deflate")
            let r = try await phone.importFile(url)
            link.acknowledge(fileID: r.fileID)
        }
        // Ack travels back; only then does the watch delete.
        XCTAssertEqual(watch.outbox.pending.count, 2)
        for id in link.acks { await watch.acknowledge(id) }
        XCTAssertEqual(watch.outbox.pending.count, 0)

        let minutes = try db.count("SELECT COUNT(*) FROM raw_chunks WHERE sensor = 'accel' AND tier = 1")
        XCTAssertEqual(minutes, 118)                         // 2 h minus the 2-minute harvest lag
        XCTAssertEqual(try db.count("SELECT MIN(sample_count) FROM raw_chunks"), 3000)
        let cov = try phone.coverage(hours: 24)
        XCTAssertEqual(cov.minutes, 118)

        // Stored payload decodes to exactly the samples sent (the engine uses the Python decoder).
        let payload = try await db.writer.read { try Data.fetchOne($0, sql: "SELECT payload FROM raw_chunks ORDER BY minute_id LIMIT 1") }!
        let chunk = try RawCodec.decode(payload)
        XCTAssertEqual(chunk.minuteID, MinuteID.from(t0 - 7200))
        XCTAssertEqual(chunk.samples.count, 3000)
    }

    func testImportIsIdempotentAndKeepsArchivedRows() async throws {
        let db = try AppDatabase.temporary("idem")
        let clock = FixedClock(Date(timeIntervalSince1970: t0))
        var c = ChunkContainer(fileID: "f", createdAt: t0, gaps: [[t0 - 600, t0 - 300]])
        let samples = try await Accel().samples(from: t0 - 180, to: t0)
        for ch in MinuteChunker.chunks(samples, sensor: .accel, rateHz: 50) { try c.append(ch, tier: 1) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("f-\(UUID()).fsc")
        try c.encoded().write(to: url)
        let imp = WatchImporter(db: db, clock: clock)
        _ = try await imp.importFile(url)
        _ = try await imp.importFile(url)
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM raw_chunks"), 3)
        // An archived minute (payload NULL) is not overwritten by a late re-send.
        try await db.writer.write { try $0.execute(sql: "UPDATE raw_chunks SET payload = NULL, archive_ref = 'x' WHERE minute_id = (SELECT MIN(minute_id) FROM raw_chunks)") }
        _ = try await imp.importFile(url)
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM raw_chunks WHERE payload IS NULL"), 1)
        XCTAssertEqual(try db.preference("raw_gap_log", as: [[Double]].self)?.count, 3)
    }

    func testPreferencesMirroredToWatch() throws {
        let env = try AppEnvironment.make(arguments: ["x", "-FengshuiTestMode", "new_user"])
        var p = RecordingPreferences()
        p.snapshotIntervalMin = 120
        env.saveRecordingPreferences(p)
        XCTAssertEqual(env.recordingPreferences().snapshotIntervalMin, 120)
        XCTAssertEqual((env.watchLink as? FakeWatchLink)?.pushed.last?.snapshotIntervalMin, 120)
    }
}
