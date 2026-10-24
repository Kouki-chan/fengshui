import FengshuiKit
import Foundation
import GRDB

/// Imports an FSC1 container from the watch into raw_chunks (spec §7.4):
/// upsert on (minute_id, sensor, tier), then the caller acknowledges the file.
struct WatchImporter: Sendable {
    struct Result: Sendable, Equatable {
        var fileID: String
        var chunks: Int
        var gapSpans: Int
    }

    let db: AppDatabase
    let clock: Clock

    func importFile(_ url: URL) async throws -> Result {
        let c = try ChunkContainer.decode(Data(contentsOf: url))
        let now = clock.now.timeIntervalSince1970
        try await db.writer.write { db in
            for (e, payload) in zip(c.index.entries, c.payloads) {
                // A re-sent file replaces the same minute's payload (identical bytes), so
                // the import is idempotent. Archived rows are left alone.
                try db.execute(sql: """
                    INSERT INTO raw_chunks (minute_id, sensor, tier, rate_hz, sample_count, axes, encoding, scale, offset,
                      payload, received_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(minute_id, sensor, tier) DO UPDATE SET
                      rate_hz = excluded.rate_hz, sample_count = excluded.sample_count, payload = excluded.payload,
                      received_at = excluded.received_at
                    WHERE raw_chunks.archive_ref IS NULL
                    """, arguments: [e.minuteID, e.sensor, e.tier, e.rateHz, e.sampleCount, e.axes, e.encoding,
                                     e.scale, e.offset, payload, now])
            }
            if !c.index.gaps.isEmpty {
                // Recorder gaps are kept for the device test's coverage numbers (spec §7.1).
                var log = (try String.fetchOne(db, sql: "SELECT value_json FROM preferences WHERE key = 'raw_gap_log'"))
                    .flatMap { try? JSONDecoder().decode([[Double]].self, from: Data($0.utf8)) } ?? []
                log += c.index.gaps
                if log.count > 2000 { log.removeFirst(log.count - 2000) }
                try db.execute(sql: """
                    INSERT INTO preferences (key, value_json, updated_at) VALUES ('raw_gap_log', ?, ?)
                    ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json, updated_at = excluded.updated_at
                    """, arguments: [String(data: try JSONEncoder().encode(log), encoding: .utf8)!, now])
            }
        }
        return Result(fileID: c.index.fileID, chunks: c.index.entries.count, gapSpans: c.index.gaps.count)
    }

    /// Minutes with tier-1 accelerometer data in the last `hours` (debug + Diagnostics).
    func coverage(hours: Double = 24) throws -> (minutes: Int, of: Int) {
        let now = clock.now.timeIntervalSince1970
        let from = MinuteID.from(now - hours * 3600)
        let n = try db.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM raw_chunks WHERE sensor = 'accel' AND tier = 1 AND minute_id >= ?",
                             arguments: [from]) ?? 0
        }
        return (n, Int(hours * 60))
    }
}
