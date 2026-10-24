import CoreMotion
import FengshuiKit
import Foundation
import GRDB

struct MotionSegment: Sendable, Equatable {
    var start: Double
    var end: Double?
    var activity: String      // stationary|walking|running|automotive|cycling|unknown
    var confidence: Int       // 0 low, 1 medium, 2 high
}

/// iPhone motion-activity history (spec §6.3). iOS keeps about 7 days.
protocol MotionHistory: Sendable {
    func segments(from: Date, to: Date) async throws -> [MotionSegment]
}

final class CoreMotionHistory: MotionHistory, @unchecked Sendable {
    private let manager = CMMotionActivityManager()

    func segments(from: Date, to: Date) async throws -> [MotionSegment] {
        guard CMMotionActivityManager.isActivityAvailable() else { return [] }
        // Converted to plain values inside the callback: CMMotionActivity isn't Sendable.
        let acts: [(start: Double, activity: String, confidence: Int)] = try await withCheckedThrowingContinuation { cont in
            manager.queryActivityStarting(from: from, to: to, to: .main) { a, e in
                if let e { cont.resume(throwing: e); return }
                cont.resume(returning: (a ?? []).map {
                    (start: $0.startDate.timeIntervalSince1970, activity: Self.label($0), confidence: $0.confidence.rawValue)
                })
            }
        }
        return Self.toSegments(acts)
    }

    /// One label per CMMotionActivity; the most specific movement wins.
    static func label(_ a: CMMotionActivity) -> String {
        if a.running { return "running" }
        if a.cycling { return "cycling" }
        if a.automotive { return "automotive" }
        if a.walking { return "walking" }
        if a.stationary { return "stationary" }
        return "unknown"
    }

    /// Consecutive activities → segments ending where the next begins (last one open).
    /// Repeats of the same label are merged.
    static func toSegments(_ acts: [(start: Double, activity: String, confidence: Int)]) -> [MotionSegment] {
        var out: [MotionSegment] = []
        for a in acts.sorted(by: { $0.start < $1.start }) {
            if var last = out.last, last.activity == a.activity {
                last.confidence = max(last.confidence, a.confidence)
                out[out.count - 1] = last
                continue
            }
            if !out.isEmpty { out[out.count - 1].end = a.start }
            out.append(MotionSegment(start: a.start, end: nil, activity: a.activity, confidence: a.confidence))
        }
        return out
    }
}

final class FakeMotionHistory: MotionHistory, @unchecked Sendable {
    var all: [MotionSegment]
    private(set) var queries: [(Double, Double)] = []
    init(_ segments: [MotionSegment] = []) { all = segments }

    convenience init(scenario: Scenario) {
        self.init(scenario.motion.map { MotionSegment(start: $0.start, end: $0.end, activity: $0.activity, confidence: $0.confidence) })
    }

    func segments(from: Date, to: Date) async throws -> [MotionSegment] {
        queries.append((from.timeIntervalSince1970, to.timeIntervalSince1970))
        return all.filter { $0.start >= from.timeIntervalSince1970 - 1 && $0.start <= to.timeIntervalSince1970 }
    }
}

/// Imports motion history since the last stored segment into context_motion.
/// Idempotent: UNIQUE(start_ts, activity); a re-queried open segment only gets its end updated.
struct MotionImporter: Sendable {
    let db: AppDatabase
    let history: MotionHistory
    let clock: Clock
    static let historyDays = 7.0

    @discardableResult
    func importNew() async throws -> Int {
        let now = clock.now
        let last = try await db.writer.read { db in try Double.fetchOne(db, sql: "SELECT MAX(start_ts) FROM context_motion") }
        let from = max(last ?? 0, now.timeIntervalSince1970 - Self.historyDays * 86400)
        let segs = try await history.segments(from: Date(timeIntervalSince1970: from), to: now)
        return try await db.writer.write { db in
            var n = 0
            for s in segs {
                try db.execute(sql: """
                    INSERT INTO context_motion (start_ts, end_ts, minute_id, activity, confidence) VALUES (?,?,?,?,?)
                    ON CONFLICT(start_ts, activity) DO UPDATE SET end_ts = COALESCE(excluded.end_ts, end_ts),
                      confidence = MAX(confidence, excluded.confidence)
                    """, arguments: [s.start, s.end, MinuteID.from(s.start), s.activity, s.confidence])
                n += db.changesCount
            }
            return n
        }
    }
}
