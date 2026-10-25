import FengshuiKit
import Foundation
import GRDB

/// Preset questions (spec §13): three dev questions seeded once; the user can add, edit,
/// disable and schedule their own. Scheduled ones run in a background task and deliver the
/// answer as a notification that opens the full answer.
struct AIQuestion: Sendable, Equatable, Identifiable {
    var id: Int64
    var owner: String          // dev | user
    var text: String
    var schedule: String?      // nil = on demand; "daily:21:00" or "weekly:sun:19:00"
    var enabled: Bool
}

struct AIQuestionStore: Sendable {
    static let seeds = ["How did I sleep this week compared with last week?",
                        "When should I start winding down tonight, and why?",
                        "How active was I today?"]
    static let lastRunKey = "ai_questions_last_run"

    let db: AppDatabase
    let clock: Clock

    func seedIfNeeded() throws {
        try db.writer.write { db in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ai_questions WHERE owner = 'dev'") == 0 else { return }
            for q in Self.seeds {
                try db.execute(sql: "INSERT INTO ai_questions (owner, text, schedule, enabled, created_at) VALUES ('dev', ?, NULL, 1, ?)",
                               arguments: [q, clock.now.timeIntervalSince1970])
            }
        }
    }

    func all() throws -> [AIQuestion] {
        try db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM ai_questions ORDER BY owner, id").map {
                AIQuestion(id: $0["id"], owner: $0["owner"], text: $0["text"], schedule: $0["schedule"],
                           enabled: ($0["enabled"] as Int) == 1)
            }
        }
    }

    @discardableResult
    func add(_ text: String, schedule: String? = nil) throws -> Int64 {
        guard schedule == nil || Self.parse(schedule!) != nil else { throw CocoaError(.formatting) }
        return try db.writer.write { db in
            try db.execute(sql: "INSERT INTO ai_questions (owner, text, schedule, enabled, created_at) VALUES ('user', ?, ?, 1, ?)",
                           arguments: [text, schedule, clock.now.timeIntervalSince1970])
            return db.lastInsertedRowID
        }
    }

    func update(_ q: AIQuestion) throws {
        guard q.schedule == nil || Self.parse(q.schedule!) != nil else { throw CocoaError(.formatting) }
        try db.writer.write { db in
            try db.execute(sql: "UPDATE ai_questions SET text = ?, schedule = ?, enabled = ? WHERE id = ?",
                           arguments: [q.text, q.schedule, q.enabled ? 1 : 0, q.id])
        }
    }

    func delete(_ id: Int64) throws {
        try db.writer.write { try $0.execute(sql: "DELETE FROM ai_questions WHERE id = ? AND owner = 'user'", arguments: [id]) }
    }

    // MARK: Scheduling

    struct Schedule: Equatable { var weekday: Int?; var hour: Int; var minute: Int }   // weekday 1 = Sunday

    static func parse(_ s: String) -> Schedule? {
        let p = s.lowercased().split(separator: ":").map(String.init)
        let days = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
        if p.count == 3, p[0] == "daily", let h = Int(p[1]), let m = Int(p[2]), (0..<24).contains(h), (0..<60).contains(m) {
            return Schedule(weekday: nil, hour: h, minute: m)
        }
        if p.count == 4, p[0] == "weekly", let d = days[p[1]], let h = Int(p[2]), let m = Int(p[3]),
           (0..<24).contains(h), (0..<60).contains(m) {
            return Schedule(weekday: d, hour: h, minute: m)
        }
        return nil
    }

    /// The most recent scheduled time at or before `now`.
    static func lastOccurrence(_ s: Schedule, before now: Date, tz: TimeZone) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var comps = DateComponents(hour: s.hour, minute: s.minute)
        comps.weekday = s.weekday
        return cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime, direction: .backward)
    }

    /// Enabled scheduled questions whose last occurrence hasn't been run yet (catch-up once, not
    /// repeatedly). A question seen for the first time starts from now, so a new schedule
    /// doesn't fire for an occurrence that passed before it existed.
    func due(tz: TimeZone) throws -> [AIQuestion] {
        let last = ((try? db.preference(Self.lastRunKey, as: [String: Double].self)) ?? nil) ?? [:]
        var out: [AIQuestion] = []
        for q in try all() {
            guard q.enabled, let s = q.schedule.flatMap(Self.parse),
                  let occ = Self.lastOccurrence(s, before: clock.now, tz: tz) else { continue }
            guard let ran = last["\(q.id)"] else { try markRun(q.id); continue }
            if ran < occ.timeIntervalSince1970 { out.append(q) }
        }
        return out
    }

    func markRun(_ id: Int64) throws {
        var last = ((try? db.preference(Self.lastRunKey, as: [String: Double].self)) ?? nil) ?? [:]
        last["\(id)"] = clock.now.timeIntervalSince1970
        try db.setPreference(Self.lastRunKey, last, now: clock.now)
    }
}

/// Runs due scheduled questions and posts each answer as a notification (BGAppRefreshTask).
struct ScheduledQuestions: Sendable {
    let store: AIQuestionStore
    let assistant: @Sendable () async -> ClaudeAssistant?
    let notifications: NotificationCenter
    let timeZone: TimeZone

    @discardableResult
    func runDue() async -> Int {
        guard let a = await assistant(), let due = try? store.due(tz: timeZone), !due.isEmpty else { return 0 }
        for q in due {
            let ans = await a.ask(q.text)
            try? store.markRun(q.id)
            let body = ans.text.count > 180 ? String(ans.text.prefix(177)) + "…" : ans.text
            try? await notifications.add(LocalNotification(identifier: "ai_answer_\(ans.logID ?? q.id)", title: q.text,
                                                           body: body, fireDate: nil,
                                                           userInfo: ["kind": "ai_answer", "ai_log_id": "\(ans.logID ?? 0)"]),
                                         timeZone: timeZone)
        }
        return due.count
    }
}
