import FengshuiKit
import Foundation
import GRDB

/// A health-monitor session on the Mac server (DECISIONS D-19), as the server reports it.
struct MonitorSession: Sendable, Equatable, Codable {
    struct Stats: Sendable, Equatable, Codable {
        var intervals = 0
        var intervalsWithData = 0
        var coverage = 0.0
        var readings = 0
        var lastReadingTs: Double?
        var requestsSent = 0
        var alerts = 0
    }

    var id: Int64
    var status: String
    var startTs: Double
    var endTs: Double
    var intervalS: Double
    var nextDueTs: Double?
    var mode: String
    var lastPushError: String?
    var stats = Stats()

    var isActive: Bool { status == "active" }

    static func from(_ j: [String: Any]?) -> MonitorSession? {
        guard let j, let id = (j["id"] as? NSNumber)?.int64Value else { return nil }
        let st = j["stats"] as? [String: Any] ?? [:]
        let d = { (o: [String: Any], k: String) in (o[k] as? NSNumber)?.doubleValue }
        return MonitorSession(id: id, status: j["status"] as? String ?? "ended", startTs: d(j, "start_ts") ?? 0,
                              endTs: d(j, "end_ts") ?? 0, intervalS: d(j, "interval_s") ?? 300, nextDueTs: d(j, "next_due_ts"),
                              mode: j["mode"] as? String ?? "pull", lastPushError: j["last_push_error"] as? String,
                              stats: Stats(intervals: Int(d(st, "intervals") ?? 0), intervalsWithData: Int(d(st, "intervals_with_data") ?? 0),
                                           coverage: d(st, "coverage") ?? 0, readings: Int(d(st, "readings") ?? 0),
                                           lastReadingTs: d(st, "last_reading_ts"), requestsSent: Int(d(st, "requests_sent") ?? 0),
                                           alerts: Int(d(st, "alerts") ?? 0)))
    }
}

/// Phone side of the monitor. Readings are processed HealthKit values (in bpm, %, /min, ms)
/// from this phone's database; live watch-session heart rate (raw) is never sent.
/// Without push (free account) it sends readings while the app is open, on background
/// refresh, and when the user taps "Send now"; with push the server's silent pushes also
/// trigger `respondToPush`.
actor MonitorClient {
    static let labels = ["heart_rate", "resting_heart_rate", "heart_rate_variability_sdnn", "oxygen_saturation",
                         "respiratory_rate", "step_count", "high_heart_rate_event", "low_heart_rate_event",
                         "irregular_heart_rhythm_event", "low_cardio_fitness_event"]
    static let baselineLabels = ["resting_heart_rate", "heart_rate_variability_sdnn", "oxygen_saturation", "respiratory_rate"]
    static let sessionKey = "monitor_session"
    static let lastSentKey = "monitor_last_sent_ts"
    static let lastAlertKey = "monitor_last_alert_id"
    static let tokenKey = "apns_token"
    static let tokenErrorKey = "apns_error"
    static let maxWindow: Double = 3 * 3600

    private let db: AppDatabase
    private let server: ServerSync
    private let clock: Clock
    private let inbox: InboxStore
    private let notifications: NotificationCenter
    private let log: EventLog
    private let deviceID: String
    private let liveSync: @Sendable () async -> Void

    init(db: AppDatabase, server: ServerSync, clock: Clock, inbox: InboxStore, notifications: NotificationCenter,
         log: EventLog, deviceID: String, liveSync: @escaping @Sendable () async -> Void) {
        self.db = db
        self.server = server
        self.clock = clock
        self.inbox = inbox
        self.notifications = notifications
        self.log = log
        self.deviceID = deviceID
        self.liveSync = liveSync
    }

    nonisolated var cached: MonitorSession? { (try? db.preference(Self.sessionKey, as: MonitorSession.self)) ?? nil }
    nonisolated var pushToken: String? { (try? db.preference(Self.tokenKey, as: String.self)) ?? nil }
    nonisolated var pushError: String? { (try? db.preference(Self.tokenErrorKey, as: String.self)) ?? nil }

    func setPushToken(_ token: String?, error: String?) {
        if let token { try? db.setPreference(Self.tokenKey, token, now: clock.now) }
        try? db.setPreference(Self.tokenErrorKey, error ?? "", now: clock.now)
        log.add("apns", token != nil ? "registered" : "failed: \(error ?? "")")
    }

    private func save(_ s: MonitorSession?) {
        if let s { try? db.setPreference(Self.sessionKey, s, now: clock.now) }
        else { try? db.writer.write { try $0.execute(sql: "DELETE FROM preferences WHERE key = ?", arguments: [Self.sessionKey]) } }
    }

    func start(intervalMin: Double, durationH: Double) async throws -> MonitorSession {
        let c = try await server.client()
        var body: [String: Any] = ["device_id": deviceID, "interval_min": intervalMin, "duration_h": durationH]
        if let t = pushToken {
            body["push_token"] = t
            #if DEBUG
            body["push_env"] = "sandbox"
            #else
            body["push_env"] = "production"
            #endif
        }
        guard let s = MonitorSession.from(try await c.post("monitor/sessions", body)) else {
            throw ServerClient.Failure.http(0, "bad session response")
        }
        save(s)
        try? db.setPreference(Self.lastSentKey, 0.0, now: clock.now)
        log.add("monitor_start", "every \(Int(intervalMin)) min for \(durationH) h")
        _ = try? await sendReadings(trigger: "start")
        return cached ?? s
    }

    func stop() async throws -> MonitorSession? {
        guard let s = cached else { return nil }
        let c = try await server.client()
        let stopped = MonitorSession.from(try await c.post("monitor/sessions/\(s.id)/stop", [:]))
        save(stopped)
        return stopped
    }

    @discardableResult
    func refresh() async throws -> MonitorSession? {
        let c = try await server.client()
        let s = MonitorSession.from((try await c.get("monitor/sessions/current", query: ["device_id": deviceID]))["session"] as? [String: Any])
        save(s)
        return s
    }

    /// Due when an interval has passed since the last batch this phone sent.
    nonisolated func isDue(_ s: MonitorSession, now: Date) -> Bool {
        let last = ((try? db.preference(Self.lastSentKey, as: Double.self)) ?? nil) ?? 0
        return s.isActive && now.timeIntervalSince1970 < s.endTs && now.timeIntervalSince1970 - last >= s.intervalS - 15
    }

    /// One check: refresh HealthKit, send everything since the last batch, file any alerts.
    @discardableResult
    func sendReadings(trigger: String) async throws -> Int {
        guard let s = cached, s.isActive else { return 0 }
        await liveSync()
        let now = clock.now.timeIntervalSince1970
        let last = ((try? db.preference(Self.lastSentKey, as: Double.self)) ?? nil) ?? 0
        let since = max(last - 300, now - Self.maxWindow, s.startTs - 1800)
        // JSON Data, not dictionaries: the result crosses GRDB's reader queue.
        let payload = try await db.writer.read { db in
            try JSONSerialization.data(withJSONObject: ["samples": try Self.samples(db, since: since),
                                                        "baselines": try Self.baselines(db, now: now)])
        }
        let p = (try JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
        let samples = p["samples"] as? [Any] ?? [], baselines = p["baselines"] ?? [String: Double]()
        let c = try await server.client()
        let r = try await c.post("monitor/readings", ["session_id": s.id, "ts": now, "trigger": trigger, "samples": samples,
                                                      "baselines": baselines])
        try? db.setPreference(Self.lastSentKey, now, now: clock.now)
        if let ns = MonitorSession.from(r["session"] as? [String: Any]) { save(ns) }
        let alerts = r["alerts"] as? [[String: Any]] ?? []
        await file(alerts)
        log.add("monitor_readings", "\(trigger) \(samples.count) samples, \(alerts.count) alerts")
        return alerts.count
    }

    /// Alerts the server made (including the end-of-session summary) that this phone hasn't filed yet.
    func pullAlerts() async {
        guard let c = try? await server.client() else { return }
        let since = ((try? db.preference(Self.lastAlertKey, as: Int64.self)) ?? nil) ?? 0
        guard let r = try? await c.get("monitor/alerts", query: ["device_id": deviceID, "since_id": "\(since)"]) else { return }
        await file(r["alerts"] as? [[String: Any]] ?? [])
    }

    private func file(_ alerts: [[String: Any]]) async {
        var maxID = ((try? db.preference(Self.lastAlertKey, as: Int64.self)) ?? nil) ?? 0
        for a in alerts {
            guard let id = (a["id"] as? NSNumber)?.int64Value else { continue }
            let title = a["title"] as? String ?? "Health monitor", body = a["body"] as? String ?? ""
            let ts = (a["ts"] as? NSNumber)?.doubleValue ?? clock.now.timeIntervalSince1970
            let identifier = "monitor-\(id)"
            let new = inbox.add(identifier: identifier, kind: "monitor", title: title, body: body,
                                at: Date(timeIntervalSince1970: ts))
            // Already shown by Apple push? Then only the inbox copy is needed.
            if new, (a["pushed"] as? NSNumber)?.intValue != 1 {
                try? await notifications.add(LocalNotification(identifier: identifier, title: title, body: body, fireDate: nil,
                                                               userInfo: ["kind": "monitor", "alert_id": "\(id)"]),
                                             timeZone: .current)
            }
            maxID = max(maxID, id)
        }
        try? db.setPreference(Self.lastAlertKey, maxID, now: clock.now)
        await inbox.updateBadge()
    }

    /// Foreground loop / background refresh: send if due, then pick up alerts.
    func tick(trigger: String) async {
        do {
            if cached?.isActive == true { try await refresh() }
            if let s = cached, isDue(s, now: clock.now) { try await sendReadings(trigger: trigger) }
            await pullAlerts()
        } catch {
            log.add("monitor_error", "\(trigger): \(error)")
        }
    }

    /// Silent push from the server (paid account): answer within iOS's ~30 s budget.
    func respondToPush() async -> Bool {
        do {
            try await refresh()
            return try await sendReadings(trigger: "push") >= 0
        } catch {
            log.add("monitor_push_error", "\(error)")
            return false
        }
    }

    // MARK: Payload (processed data only)

    static func samples(_ db: Database, since: Double) throws -> [[String: Any]] {
        let marks = labels.map { _ in "?" }.joined(separator: ",")
        return try Row.fetchAll(db, sql: """
            SELECT label, value, value_text, unit, start_ts, end_ts FROM processed_samples
            WHERE deleted = 0 AND label IN (\(marks)) AND start_ts >= ? ORDER BY start_ts LIMIT 5000
            """, arguments: StatementArguments(labels + [since])!).map { r in
            let label: String = r["label"]
            var s: [String: Any] = ["label": label, "ts": r["start_ts"] as Double, "end_ts": r["end_ts"] as Double]
            if let v = r["value"] as Double? {
                let (nv, u) = DataSnapshot.normalize(label: label, value: v, unit: r["unit"])
                s["value"] = nv
                s["unit"] = u
            } else {
                s["text"] = (r["value_text"] as String?) ?? "event"
            }
            return s
        }
    }

    /// 30-day medians of the slow-moving vitals: the user's own normal for the rules.
    static func baselines(_ db: Database, now: Double) throws -> [String: Double] {
        var out: [String: Double] = [:]
        for label in baselineLabels {
            let rows = try Row.fetchAll(db, sql: """
                SELECT value, unit FROM processed_samples WHERE label = ? AND deleted = 0 AND value IS NOT NULL
                AND start_ts >= ? ORDER BY start_ts DESC LIMIT 3000
                """, arguments: [label, now - 30 * 86_400])
            let vals = rows.map { DataSnapshot.normalize(label: label, value: $0["value"], unit: $0["unit"]).0 }.sorted()
            if !vals.isEmpty { out[label] = vals[vals.count / 2] }
        }
        return out
    }
}
