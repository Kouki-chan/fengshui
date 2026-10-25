import FengshuiKit
import Foundation
import GRDB

/// Runs the embedded Python engine (spec §8–9). An actor, so runs are serialized:
/// one at a time, always off the main thread.
actor EngineRunner {
    enum Location: String, Codable, CaseIterable, Sendable { case phone, server, auto }

    struct RunRecord: Codable, Sendable, Equatable {
        var ts: Double
        var trigger: String
        var location: String?          // phone | server (nil in older log entries)
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
    static let locationKey = "compute_location"
    /// Auto prefers the server when this many raw minutes still need features (spec §8: > 24 h).
    static let backlogMinutes = 24 * 60

    private let db: AppDatabase
    private let clock: Clock
    private let timeZone: TimeZone
    private let python: EmbeddedPython
    private let log: EventLog
    /// Called after a run that wrote inferences (notifications scheduling, Phase 5).
    private let afterRun: @Sendable (RunRecord) async -> Void
    private let server: ServerSync?
    private let lowPowerMode: @Sendable () -> Bool

    init(db: AppDatabase, clock: Clock, timeZone: TimeZone, python: EmbeddedPython = .shared,
         log: EventLog, server: ServerSync? = nil,
         lowPowerMode: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
         afterRun: @escaping @Sendable (RunRecord) async -> Void = { _ in }) {
        self.server = server
        self.lowPowerMode = lowPowerMode
        self.db = db
        self.clock = clock
        self.timeZone = timeZone
        self.python = python
        self.log = log
        self.afterRun = afterRun
    }

    nonisolated var location: Location {
        ((try? db.preference(Self.locationKey, as: Location.self)) ?? nil) ?? .auto
    }

    /// Spec §8: Auto = phone, unless Low Power Mode or a > 24 h raw backlog, and the server is reachable.
    func chooseServer() async -> Bool {
        guard let server else { return false }
        switch location {
        case .phone: return false
        case .server: return true
        case .auto:
            let backlog = (try? await db.writer.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(DISTINCT c.minute_id) FROM raw_chunks c LEFT JOIN raw_minute_features f ON f.minute_id = c.minute_id
                    WHERE c.payload IS NOT NULL AND f.minute_id IS NULL
                    """) ?? 0
            }) ?? 0
            guard lowPowerMode() || backlog > Self.backlogMinutes else { return false }
            return await server.reachable()
        }
    }

    @discardableResult
    func run(_ tasks: [String] = EngineRunner.allTasks, trigger: String) async -> RunRecord {
        let now = clock.now.timeIntervalSince1970
        let t0 = Date()
        var rec = RunRecord(ts: now, trigger: trigger, tasks: tasks, ok: true, seconds: 0, rowsWritten: 0, error: nil)
        if let server, await chooseServer() {
            do {
                rec.location = "server"
                rec.rowsWritten = try await server.compute(tasks: tasks, tz: timeZone)
                return await finish(rec, t0)
            } catch {
                // The server is a helper, never a dependency: fall back to the phone.
                log.add("server_compute_error", "\(error)")
                rec.location = "phone (server failed)"
            }
        }
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
        return await finish(rec, t0)
    }

    private func finish(_ r: RunRecord, _ t0: Date) async -> RunRecord {
        var rec = r
        let trigger = rec.trigger, tasks = rec.tasks
        rec.seconds = Date().timeIntervalSince(t0)
        log.add(rec.ok ? "engine_run" : "engine_error",
                "\(trigger) \(tasks.joined(separator: ",")) +\(rec.rowsWritten) \(String(format: "%.2f", rec.seconds))s \(rec.error ?? "")")
        appendLog(rec)
        await afterRun(rec)
        // Screens showing inferences (Today) refresh on this.
        await MainActor.run { Foundation.NotificationCenter.default.post(name: .engineDidRun, object: nil) }
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

extension Notification.Name {
    static let engineDidRun = Notification.Name("FengshuiEngineDidRun")
}
