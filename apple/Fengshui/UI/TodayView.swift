import GRDB
import SwiftUI

/// Spec §15 Today: tonight's wind-down plan (with reasons), today's activity timeline, quick stats.
struct TodayView: View {
    let env: AppEnvironment
    @State private var plan: [String: Any] = [:]
    @State private var bouts: [[String: Any]] = []
    @State private var day: [String: Any] = [:]

    var body: some View {
        List {
            Section("Tonight") {
                if let start = plan["wind_down_start"] as? String {
                    LabeledContent("Start winding down", value: start).font(.headline)
                        .accessibilityIdentifier("today.windDownStart")
                    LabeledContent("In bed by", value: plan["target_in_bed"] as? String ?? "–")
                    LabeledContent("Asleep around", value: plan["target_sleep_onset"] as? String ?? "–")
                    LabeledContent("Expected wake", value: "\(plan["predicted_wake"] as? String ?? "–") (\(plan["day_type_tomorrow"] as? String ?? ""))")
                    ForEach(explanations, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text("No plan yet — it appears once Fengshui has run.").foregroundStyle(.secondary)
                }
            }
            Section("Today") {
                if let steps = day["steps"] as? Int {
                    LabeledContent("Steps", value: "\(steps)")
                    LabeledContent("Moderate + vigorous", value: "\(day["mvpa_minutes"] as? Int ?? 0) min")
                    LabeledContent("Longest sitting", value: "\(day["longest_sedentary_min"] as? Int ?? 0) min")
                }
                ForEach(Array(bouts.enumerated()), id: \.offset) { _, b in
                    HStack {
                        Text(time(b["start"])).monospacedDigit().foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                        VStack(alignment: .leading) {
                            Text(title(b)).font(.subheadline)
                            Text("\(b["minutes"] as? Int ?? 0) min · \(b["place"] as? String ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Today")
        .onReceive(Foundation.NotificationCenter.default.publisher(for: .engineDidRun)) { _ in reload() }
        .refreshable { await env.engine.run(EngineRunner.lightTasks, trigger: "pull_to_refresh"); reload() }
        .task { reload() }
    }

    private var explanations: [String] {
        var out = [String]()
        if let need = plan["sleep_need_min"] as? Int { out.append("Sleep need ≈ \(need / 60) h \(need % 60) min") }
        if let extra = plan["extra_tonight_min"] as? Int, extra > 0 {
            out.append("+\(extra) min tonight for \(plan["sleep_debt_min"] as? Int ?? 0) min of sleep debt")
        }
        for a in plan["adjustments"] as? [[String: Any]] ?? [] {
            out.append("\(a["minutes"] as? Int ?? 0) min: \((a["reason"] as? String ?? "").replacingOccurrences(of: "_", with: " "))")
        }
        for r in plan["reasons"] as? [String] ?? [] { out.append(r.replacingOccurrences(of: "_", with: " ")) }
        return out
    }

    private func title(_ b: [String: Any]) -> String {
        var t = (b["workout_type"] as? String ?? b["label"] as? String ?? "").replacingOccurrences(of: "_", with: " ").capitalized
        if let i = b["intensity"] as? String { t += " · \(i)" }
        return t
    }

    private func time(_ iso: Any?) -> String {
        guard let s = iso as? String, let t = s.split(separator: "T").last else { return "" }
        return String(t.prefix(5))
    }

    private func reload() {
        let now = env.clock.now.timeIntervalSince1970
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = env.timeZone
        let dayStart = cal.startOfDay(for: env.clock.now).timeIntervalSince1970
        try? env.db.writer.read { db in
            if let s = try String.fetchOne(db, sql: """
                SELECT value_json FROM inferences WHERE kind = 'wind_down_plan' AND superseded_by IS NULL
                ORDER BY json_extract(value_json, '$.night_of') DESC, id DESC LIMIT 1
                """) { plan = Self.obj(s) }
            bouts = try String.fetchAll(db, sql: """
                SELECT value_json FROM inferences WHERE kind = 'activity_bout' AND superseded_by IS NULL
                AND minute_end > ? AND minute_start < ? ORDER BY minute_start DESC
                """, arguments: [Int(dayStart / 60), Int(now / 60)]).map(Self.obj)
                .filter { ($0["label"] as? String) != "unknown" }
            if let s = try String.fetchOne(db, sql: """
                SELECT value_json FROM inferences WHERE kind = 'activity_day' AND superseded_by IS NULL
                AND minute_start = ? ORDER BY id DESC LIMIT 1
                """, arguments: [Int(dayStart / 60)]) { day = Self.obj(s) }
        }
    }

    static func obj(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }
}

/// Settings → Wind-down: tomorrow's wake override, wind-down length, notifications on/off (spec §15).
struct WindDownSettingsView: View {
    let env: AppEnvironment
    @State private var notificationsOn = true
    @State private var overrideOn = false
    @State private var wake = SleepQuestionsView.time(7, 0)
    @State private var length = 60.0

    var body: some View {
        Form {
            Toggle("Wind-down reminders", isOn: $notificationsOn)
                .accessibilityIdentifier("wd.notifications")
            Section {
                Toggle("Tomorrow I wake at…", isOn: $overrideOn)
                if overrideOn { DatePicker("Wake", selection: $wake, displayedComponents: .hourAndMinute) }
            } footer: { Text("A one-off: replaces the predicted wake time for tomorrow only.") }
            Section {
                Stepper("Wind-down length \(Int(length)) min", value: $length, in: 30...90, step: 15)
            } footer: { Text("Fengshui also adjusts this from how long you take to fall asleep.") }
            Button("Save") { Task { await save() } }.accessibilityIdentifier("wd.save")
        }
        .navigationTitle("Wind-down")
        .task {
            notificationsOn = await env.windDown.enabled
            if let v = (try? env.engineState("wind_down.len")).flatMap(Double.init) { length = v }
        }
    }

    private func save() async {
        try? env.db.setPreference(WindDownScheduler.enabledKey, notificationsOn, now: env.clock.now)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = env.timeZone
        if overrideOn, let tomorrow = cal.date(byAdding: .day, value: 1, to: env.clock.now) {
            let d = cal.dateComponents([.year, .month, .day], from: tomorrow)
            try? env.db.setPreference("wake_override", ["date": String(format: "%04d-%02d-%02d", d.year!, d.month!, d.day!),
                                                        "time": SleepQuestionsView.hhmm(wake)], now: env.clock.now)
        }
        // The engine owns engine_state; it applies this user choice once (spec §4 table ownership).
        try? env.db.setPreference("wind_down_len_user", ["value": length, "set_at": env.clock.now.timeIntervalSince1970],
                                  now: env.clock.now)
        if !notificationsOn { await env.windDown.cancelAll() }
        await env.engine.run(["wind_down"], trigger: "settings")
    }
}

struct SigningRow: View {
    var body: some View {
        if let exp = SigningExpiry.expirationDate() {
            LabeledContent("Signing expires in", value: "\(SigningExpiry.daysLeft(exp, now: Date())) days")
        } else {
            LabeledContent("Signing", value: "no profile (simulator)")
        }
    }
}

struct NotificationLogView: View {
    struct Entry: Sendable {
        var identifier: String
        var scheduled: Double?
        var delivered: Double?
        var cancelled: Double?
    }

    let env: AppEnvironment
    @State private var rows: [Entry] = []

    var body: some View {
        List(Array(rows.enumerated()), id: \.offset) { _, r in
            VStack(alignment: .leading) {
                Text(r.identifier).font(.caption.bold())
                Text(line(r)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Notification log")
        .task {
            await env.windDown.reconcileDelivered()
            rows = (try? await env.db.writer.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM notifications_log ORDER BY id DESC LIMIT 100").map {
                    Entry(identifier: $0["identifier"], scheduled: $0["scheduled_for"], delivered: $0["delivered_at"],
                          cancelled: $0["cancelled_at"])
                }
            }) ?? []
        }
    }

    private func line(_ r: Entry) -> String {
        let f: (Double?) -> String = { $0.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "–" }
        var s = "scheduled \(f(r.scheduled))"
        if let d = r.delivered, let p = r.scheduled { s += " · delivered \(f(d)) · delay \(Int(d - p)) s" }
        if let c = r.cancelled { s += " · cancelled \(f(c))" }
        return s
    }
}

extension AppEnvironment {
    func engineState(_ key: String) throws -> String? {
        try db.writer.read { try String.fetchOne($0, sql: "SELECT value FROM engine_state WHERE key = ?", arguments: [key]) }
    }
}
