import FengshuiKit
import Foundation
import GRDB

/// Runs the embedded Python engine (spec §8–9). An actor, so runs are serialized:
/// one at a time, always off the main thread.
actor EngineRunner {
    struct RunRecord: Codable, Sendable, Equatable {
        var ts: Double
        var trigger: String
        var tasks: [String]
        var ok: Bool
        var seconds: Double
        var rowsWritten: Int
        var error: String?
    }

    /// Spec §9: light work for app refresh, everything for processing / foreground.
    static let lightTasks = ["activity", "wind_down"]
    static let allTasks = ["features", "activity", "wind_down_outcome", "wind_down", "place_suggestions"]
    static let logKey = "engine_runs"
    static let logLimit = 50

    private let db: AppDatabase
    private let clock: Clock
    private let timeZone: TimeZone
    private let python: EmbeddedPython
    private let log: EventLog
    /// Called after a run that wrote inferences (notifications scheduling, Phase 5).
    private let afterRun: @Sendable (RunRecord) async -> Void

    init(db: AppDatabase, clock: Clock, timeZone: TimeZone, python: EmbeddedPython = .shared,
         log: EventLog, afterRun: @escaping @Sendable (RunRecord) async -> Void = { _ in }) {
        self.db = db
        self.clock = clock
        self.timeZone = timeZone
        self.python = python
        self.log = log
        self.afterRun = afterRun
    }

    @discardableResult
    func run(_ tasks: [String] = EngineRunner.allTasks, trigger: String) async -> RunRecord {
        let now = clock.now.timeIntervalSince1970
        let t0 = Date()
        var rec = RunRecord(ts: now, trigger: trigger, tasks: tasks, ok: true, seconds: 0, rowsWritten: 0, error: nil)
        do {
            // The engine reads the time zone the Swift side stores (spec §4).
            try db.setPreference("time_zone", timeZone.identifier, now: clock.now)
            let summary = try python.call("run", ["db_path": db.path, "now_ts": now, "tz": timeZone.identifier,
                                                  "where": "phone", "tasks": tasks]) as? [String: Any] ?? [:]
            let perTask = summary["tasks"] as? [String: [String: Any]] ?? [:]
            rec.rowsWritten = perTask.values.reduce(0) { $0 + (($1["rows_written"] as? Int) ?? 0) }
        } catch {
            rec.ok = false
            rec.error = "\(error)"
        }
        rec.seconds = Date().timeIntervalSince(t0)
        log.add(rec.ok ? "engine_run" : "engine_error",
                "\(trigger) \(tasks.joined(separator: ",")) +\(rec.rowsWritten) \(String(format: "%.2f", rec.seconds))s \(rec.error ?? "")")
        appendLog(rec)
        await afterRun(rec)
        return rec
    }

    private func appendLog(_ r: RunRecord) {
        var all = (try? db.preference(Self.logKey, as: [RunRecord].self)) ?? []
        all.append(r)
        if all.count > Self.logLimit { all.removeFirst(all.count - Self.logLimit) }
        try? db.setPreference(Self.logKey, all, now: clock.now)
    }

    nonisolated func history() -> [RunRecord] {
        ((try? db.preference(Self.logKey, as: [RunRecord].self)) ?? []).reversed()
    }
}
