import FengshuiKit
import Foundation
import GRDB

/// Spec §11. Planned prompts: every new or superseding wind_down_plan (re)schedules a
/// calendar-triggered local notification `wind_down_<night_of>` at wind_down_start.
/// Place-triggered prompts: arriving Home within 90 min after wind_down_start sends one
/// immediately, unless tonight's prompt was dismissed. Everything is logged in
/// notifications_log so the delivery delay can be measured.
actor WindDownScheduler {
    struct Plan: Sendable, Equatable {
        var inferenceID: Int64
        var nightOf: String
        var start: Date
        var json: [String: String]
        var reasons: [String]
    }

    static let homePromptWindow: TimeInterval = 90 * 60
    static let enabledKey = "wind_down_notifications"
    static let dismissedKey = "wind_down_dismissed"

    private let db: AppDatabase
    private let center: NotificationCenter
    private let clock: Clock
    private let timeZone: TimeZone
    private let log: EventLog

    init(db: AppDatabase, center: NotificationCenter, clock: Clock, timeZone: TimeZone, log: EventLog) {
        self.db = db
        self.center = center
        self.clock = clock
        self.timeZone = timeZone
        self.log = log
    }

    static func identifier(_ nightOf: String) -> String { "wind_down_\(nightOf)" }
    static func homeIdentifier(_ nightOf: String) -> String { "wind_down_home_\(nightOf)" }

    /// The current (non-superseded) plan with the latest night.
    func latestPlan() throws -> Plan? {
        try db.writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, minute_start, value_json FROM inferences WHERE kind = 'wind_down_plan' AND superseded_by IS NULL
                ORDER BY json_extract(value_json, '$.night_of') DESC, id DESC LIMIT 1
                """) else { return nil }
            let obj = (try? JSONSerialization.jsonObject(with: Data((row["value_json"] as String).utf8))) as? [String: Any] ?? [:]
            var flat: [String: String] = [:]
            for (k, v) in obj where v is String { flat[k] = v as? String }
            return Plan(inferenceID: row["id"], nightOf: obj["night_of"] as? String ?? "",
                        start: Date(timeIntervalSince1970: Double(row["minute_start"] as Int64) * 60),
                        json: flat, reasons: obj["reasons"] as? [String] ?? [])
        }
    }

    var enabled: Bool { ((try? db.preference(Self.enabledKey, as: Bool.self)) ?? nil) ?? true }

    /// Call after every engine run. Idempotent.
    func sync() async {
        do {
            guard let plan = try latestPlan() else { return }
            let id = Self.identifier(plan.nightOf)
            let pending = await center.pending().first { $0.identifier == id }
            guard enabled else {
                if pending != nil { await cancel(id, reason: "disabled") }
                return
            }
            // Never schedule in the past; a plan that is already due is left alone.
            guard plan.start > clock.now else { return }
            if let p = pending, let d = p.fireDate, abs(d.timeIntervalSince(plan.start)) < 1 { return }
            if pending != nil { await cancel(id, reason: "rescheduled") }
            let n = LocalNotification(identifier: id, title: "Time to wind down",
                                      body: body(plan), fireDate: plan.start,
                                      userInfo: ["night_of": plan.nightOf, "kind": "wind_down"])
            try await center.add(n, timeZone: timeZone)
            try logRow(inference: plan.inferenceID, kind: "wind_down", id: id, scheduledFor: plan.start)
            log.add("notif_scheduled", "\(id) \(plan.json["wind_down_start"] ?? "")")
        } catch {
            log.add("notif_error", "\(error)")
        }
    }

    private func body(_ p: Plan) -> String {
        var s = "Aim to be in bed by \(p.json["target_in_bed"] ?? "?") and asleep around \(p.json["target_sleep_onset"] ?? "?")."
        if let w = p.json["predicted_wake"] { s += " Expected wake: \(w)." }
        return s
    }

    private func cancel(_ id: String, reason: String) async {
        await center.removePending([id])
        let now = clock.now.timeIntervalSince1970
        try? await db.writer.write { db in
            try db.execute(sql: """
                UPDATE notifications_log SET cancelled_at = ? WHERE identifier = ? AND delivered_at IS NULL AND cancelled_at IS NULL
                """, arguments: [now, id])
        }
        log.add("notif_cancelled", "\(id) \(reason)")
    }

    /// Cancels tonight's planned prompt (e.g. notifications switched off).
    func cancelAll() async {
        for p in await center.pending() where p.identifier.hasPrefix("wind_down_") { await cancel(p.identifier, reason: "cancel_all") }
    }

    // MARK: Home arrival (spec §10.2 step 7, §11)

    /// Returns true if a prompt was sent.
    @discardableResult
    func homeArrival(at ts: Double) async -> Bool {
        guard enabled, let plan = try? latestPlan() else { return false }
        let arrival = Date(timeIntervalSince1970: ts)
        // Arriving after wind_down_start means they weren't Home at the start.
        guard arrival >= plan.start, arrival <= plan.start.addingTimeInterval(Self.homePromptWindow) else { return false }
        if ((try? db.preference(Self.dismissedKey, as: String.self)) ?? nil) == plan.nightOf { return false }
        let id = Self.homeIdentifier(plan.nightOf)
        let already = (try? await db.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notifications_log WHERE identifier = ?", arguments: [id])
        }) ?? 0
        guard already == 0 else { return false }
        do {
            try await center.add(LocalNotification(identifier: id, title: "Welcome home — time to wind down",
                                                   body: "You planned to start at \(plan.json["wind_down_start"] ?? "?"). Bed by \(plan.json["target_in_bed"] ?? "?").",
                                                   fireDate: nil, userInfo: ["night_of": plan.nightOf, "kind": "wind_down_home"]),
                                 timeZone: timeZone)
            try logRow(inference: plan.inferenceID, kind: "wind_down_home", id: id, scheduledFor: arrival)
            log.add("notif_home", id)
            return true
        } catch {
            log.add("notif_error", "\(error)")
            return false
        }
    }

    func dismissTonight(_ nightOf: String) {
        try? db.setPreference(Self.dismissedKey, nightOf, now: clock.now)
    }

    // MARK: Delivery logging

    /// willPresent / didReceive (app in foreground or tapped).
    func markDelivered(_ id: String, at date: Date) {
        try? db.writer.write { db in
            try db.execute(sql: """
                UPDATE notifications_log SET delivered_at = ? WHERE identifier = ? AND delivered_at IS NULL AND cancelled_at IS NULL
                """, arguments: [date.timeIntervalSince1970, id])
        }
    }

    /// On foreground: delivered notifications still in Notification Center carry their delivery time.
    func reconcileDelivered() async {
        for d in await center.delivered() { markDelivered(d.identifier, at: d.date) }
    }

    private func logRow(inference: Int64?, kind: String, id: String, scheduledFor: Date) throws {
        let now = clock.now.timeIntervalSince1970
        try db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO notifications_log (inference_id, kind, identifier, scheduled_for, created_at) VALUES (?,?,?,?,?)
                """, arguments: [inference, kind, id, scheduledFor.timeIntervalSince1970, now])
        }
    }

    /// Delivery delays in seconds (delivered − scheduled), for the debug screen and Diagnostics.
    func delays() throws -> [(identifier: String, seconds: Double)] {
        try db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT identifier, delivered_at - scheduled_for AS d FROM notifications_log
                WHERE delivered_at IS NOT NULL ORDER BY id
                """).map { ($0["identifier"], $0["d"]) }
        }
    }
}
