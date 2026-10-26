import GRDB
import XCTest
@testable import Fengshui

final class DataViewTests: XCTestCase {
    let tz = TimeZone(identifier: "America/New_York")!
    // 2026-10-20 14:00 New York.
    let now = Date(timeIntervalSince1970: 1_792_519_200)

    private func insert(_ d: Database, _ label: String, _ value: Double?, unit: String?, at ts: Double, end: Double? = nil,
                        text: String? = nil, source: String = "Watch") throws {
        try d.execute(sql: """
            INSERT INTO processed_samples (hk_uuid, hk_type, label, value, value_text, unit, start_ts, end_ts, minute_id,
                                           source_name, inserted_at)
            VALUES (?, 'T', ?, ?, ?, ?, ?, ?, ?, ?, 0)
            """, arguments: [UUID().uuidString, label, value, text, unit, ts, end ?? ts, Int(ts / 60), source])
    }

    func testSnapshotNormalisesUnitsAndTakesPerSourceMaxForTotals() throws {
        let db = try AppDatabase.temporary("dataview")
        let t = now.timeIntervalSince1970
        try db.writer.write { d in
            try insert(d, "heart_rate", 1.2, unit: "count/s", at: t - 600)          // 72 bpm
            try insert(d, "heart_rate", 80, unit: "count/min", at: t - 120)
            try insert(d, "oxygen_saturation", 0.97, unit: "%", at: t - 3_600)
            // Steps: watch 3000 + 1000, phone 3500 → per-source max 4000, not 7500.
            try insert(d, "step_count", 3_000, unit: "count", at: t - 7_200)
            try insert(d, "step_count", 1_000, unit: "count", at: t - 3_600)
            try insert(d, "step_count", 3_500, unit: "count", at: t - 3_600, source: "iPhone")
            try insert(d, "step_count", 9_999, unit: "count", at: t - 86_400)       // yesterday: excluded
            try insert(d, "distance_walking_running", 2_500, unit: "m", at: t - 3_600)
            // Sleep last night (starts 23:00, 7 h asleep of which 1 h deep, 20 min awake).
            let bed = t - 15 * 3_600
            try insert(d, "sleep_analysis", nil, unit: nil, at: bed, end: bed + 6 * 3_600, text: "asleep_core")
            try insert(d, "sleep_analysis", nil, unit: nil, at: bed + 6 * 3_600, end: bed + 7 * 3_600, text: "asleep_deep")
            try insert(d, "sleep_analysis", nil, unit: nil, at: bed + 7 * 3_600, end: bed + 7 * 3_600 + 1_200, text: "awake")
            try insert(d, "sleep_analysis", nil, unit: nil, at: bed, end: bed + 8 * 3_600, text: "in_bed")
            try d.execute(sql: """
                INSERT INTO raw_chunks (minute_id, sensor, tier, rate_hz, sample_count, axes, encoding, scale, payload, received_at)
                VALUES (?, 'accel', 1, 50, 3000, 3, 'fsr1-i16-delta-deflate', 0.00048828125, x'00', ?)
                """, arguments: [Int(t / 60) - 5, t - 240])
        }

        let s = try db.writer.read { try DataSnapshot.fetch($0, now: self.now, timeZone: self.tz) }
        let hr = try XCTUnwrap(s.vitals.first { $0.label == "heart_rate" })
        XCTAssertEqual(hr.value, 80)
        XCTAssertEqual(hr.unit, "bpm")
        XCTAssertEqual(hr.series.map(\.value).reduce(0, +) / Double(hr.series.count), 76, accuracy: 4)
        XCTAssertEqual(s.vitals.first { $0.label == "oxygen_saturation" }?.value ?? 0, 97, accuracy: 0.01)
        XCTAssertEqual(s.totals.first { $0.label == "step_count" }?.value, 4_000)
        XCTAssertEqual(s.totals.first { $0.label == "distance_walking_running" }?.unit, "km")
        XCTAssertEqual(s.sleep.asleep, 7 * 3_600)
        XCTAssertEqual(s.sleep.deep, 3_600)
        XCTAssertEqual(s.sleep.awake, 1_200)
        XCTAssertEqual(s.watch.accelMinutes24h, 1)
        XCTAssertEqual(s.watch.lastReceived, now.timeIntervalSince1970 - 240)
        XCTAssertEqual(s.recent.count, 8)
        XCTAssertFalse(s.isEmpty)
    }

    func testEmptyDatabaseIsEmpty() throws {
        let db = try AppDatabase.temporary("dataview-empty")
        let s = try db.writer.read { try DataSnapshot.fetch($0, now: self.now, timeZone: self.tz) }
        XCTAssertTrue(s.isEmpty)
    }

    /// The tab's live update path: a write after the observation starts produces a new snapshot.
    func testObservationEmitsAfterNewSamples() async throws {
        let db = try AppDatabase.temporary("dataview-live")
        let now = self.now, tz = self.tz
        let observation = ValueObservation.tracking { try DataSnapshot.fetch($0, now: now, timeZone: tz) }.removeDuplicates()
        var iterator = observation.values(in: db.writer).makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.vitals.count, 0)
        try await db.writer.write { d in
            try d.execute(sql: """
                INSERT INTO processed_samples (hk_uuid, hk_type, label, value, unit, start_ts, end_ts, minute_id, inserted_at)
                VALUES ('live-1', 'T', 'heart_rate', 66, 'count/min', ?, ?, 0, 0)
                """, arguments: [now.timeIntervalSince1970 - 30, now.timeIntervalSince1970 - 30])
        }
        let second = try await iterator.next()
        XCTAssertEqual(second?.vitals.first?.value, 66)
    }

    func testDetailUsesDailyTotalsForCumulativeTypes() throws {
        let db = try AppDatabase.temporary("dataview-detail")
        let t = now.timeIntervalSince1970
        try db.writer.write { d in
            for day in 0..<3 { try insert(d, "step_count", Double(1_000 * (day + 1)), unit: "count", at: t - Double(day) * 86_400) }
        }
        let detail = try db.writer.read { try DataTypeDetailView.fetch($0, label: "step_count", now: self.now, timeZone: self.tz) }
        XCTAssertEqual(detail.points.map(\.value), [3_000, 2_000, 1_000])
        XCTAssertEqual(detail.samples.count, 3)
    }

    func testNormalize() {
        XCTAssertEqual(DataSnapshot.normalize(label: "respiratory_rate", value: 0.25, unit: "count/s").1, "/min")
        XCTAssertEqual(DataSnapshot.normalize(label: "respiratory_rate", value: 0.25, unit: "count/s").0, 15)
        XCTAssertEqual(DataSnapshot.normalize(label: "distance_walking_running", value: 800, unit: "m").1, "m")
        XCTAssertEqual(DataSnapshot.normalize(label: "step_count", value: 10, unit: "count").1, "steps")
    }
}
