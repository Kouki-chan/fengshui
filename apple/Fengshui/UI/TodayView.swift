import GRDB
import SwiftUI

/// Spec §15 Today: tonight's wind-down plan (with reasons), today's activity timeline, quick stats.
/// Reads off the main thread and only redraws when the underlying rows changed, so switching
/// back to this tab is instant.
struct TodayView: View {
    /// The raw JSON rows; compared before parsing so an unchanged reload costs nothing.
    struct Rows: Equatable, Sendable {
        var plan: String?
        var bouts: [String] = []
        var day: String?
    }

    let env: AppEnvironment
    let ui: UIState
    @Environment(\.theme) private var theme
    @State private var rows: Rows?
    @State private var plan: [String: Any] = [:]
    @State private var bouts: [[String: Any]] = []
    @State private var day: [String: Any] = [:]
    @State private var showReasons = false

    private let grid = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(env.clock.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 4)
                SnippetCard(ui: ui) { ui.openProfile() }
                tonight
                if let steps = day["steps"] as? Int { stats(steps) }
                if !bouts.isEmpty { timeline }
                askShortcuts
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 28)
        }
        .themedBackground()
        .navigationTitle("Today")
        .onReceive(Foundation.NotificationCenter.default.publisher(for: .engineDidRun)) { _ in
            Task { await reload(); await ui.snippets.refresh() }
        }
        .refreshable {
            // The engine run can take a while (especially on the Mac server), so it isn't awaited:
            // the spinner closes now, and .engineDidRun reloads this screen when the run finishes.
            let engine = env.engine
            Task.detached { await engine.run(EngineRunner.lightTasks, trigger: "pull_to_refresh") }
            await reload()
            await ui.snippets.refresh()
        }
        .task { await reload(); await ui.snippets.refresh() }
    }

    // MARK: Sections

    @ViewBuilder private var tonight: some View {
        if let start = plan["wind_down_start"] as? String {
            VStack(alignment: .leading, spacing: 14) {
                Label("Tonight", systemImage: "moon.stars.fill").font(.footnote.weight(.semibold)).textCase(.uppercase)
                    .opacity(0.85)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Start winding down").font(.headline)
                    Text(start).font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
                        .accessibilityIdentifier("today.windDownStart")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { chips }
                    VStack(alignment: .leading, spacing: 8) { chips }
                }
                if !explanations.isEmpty {
                    Button { withAnimation(.snappy) { showReasons.toggle() } } label: {
                        HStack {
                            Text("Why this time?")
                            Image(systemName: "chevron.down").rotationEffect(.degrees(showReasons ? 180 : 0))
                        }
                        .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    if showReasons {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(explanations, id: \.self) { Label($0, systemImage: "checkmark.circle").font(.caption) }
                        }
                        .opacity(0.9)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .foregroundStyle(theme.onHero)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.heroGradient, in: .rect(cornerRadius: 24, style: .continuous))
            .shadow(color: theme.heroEnd.opacity(0.25), radius: 14, y: 6)
        } else {
            Card {
                HStack(spacing: 14) {
                    IconBadge(systemImage: "moon.stars.fill", tint: theme.sleep, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tonight").font(.headline)
                        Text("No plan yet. It appears once HealthBot has run.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var chips: some View {
        let glass = Color.white.opacity(0.18)
        Chip(text: "In bed \(plan["target_in_bed"] as? String ?? "–")", systemImage: "bed.double.fill",
             foreground: theme.onHero, background: glass)
        Chip(text: "Asleep \(plan["target_sleep_onset"] as? String ?? "–")", systemImage: "zzz",
             foreground: theme.onHero, background: glass)
        Chip(text: "Wake \(plan["predicted_wake"] as? String ?? "–")\((plan["day_type_tomorrow"] as? String).map { " · \($0)" } ?? "")",
             systemImage: "sunrise.fill", foreground: theme.onHero, background: glass)
    }

    private func stats(_ steps: Int) -> some View {
        CardSection(title: "Today", systemImage: "figure.walk", tint: theme.activity) {
            LazyVGrid(columns: grid, spacing: 10) {
                StatTile(title: "Steps", value: steps.formatted(), unit: "", caption: "since midnight",
                         systemImage: "figure.walk", tint: theme.activity)
                StatTile(title: "Moderate + vigorous", value: "\(day["mvpa_minutes"] as? Int ?? 0)", unit: "min",
                         caption: "active minutes", systemImage: "flame.fill", tint: theme.heart)
                StatTile(title: "Longest sitting", value: "\(day["longest_sedentary_min"] as? Int ?? 0)", unit: "min",
                         caption: "in one stretch", systemImage: "chair.lounge.fill", tint: theme.sleep)
            }
        }
    }

    private var timeline: some View {
        CardSection(title: "Activity", systemImage: "clock", tint: theme.tint) {
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(bouts.enumerated()), id: \.offset) { i, b in
                        HStack(alignment: .top, spacing: 12) {
                            Text(time(b["start"])).font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .leading)
                            VStack(spacing: 0) {
                                Circle().fill(theme.activity).frame(width: 10, height: 10).padding(.top, 3)
                                if i < bouts.count - 1 { Rectangle().fill(theme.activity.opacity(0.25)).frame(width: 2) }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(b)).font(.subheadline.weight(.medium))
                                Text("\(b["minutes"] as? Int ?? 0) min\((b["place"] as? String).flatMap { $0.isEmpty ? nil : " · \($0)" } ?? "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.bottom, 14)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private var askShortcuts: some View {
        CardSection(title: "Ask HealthBot", systemImage: "sparkles", tint: theme.highlight) {
            VStack(spacing: 10) {
                ForEach(["How did I sleep last night?", "How active was I today?"], id: \.self) { q in
                    Button {
                        ui.ask.send(q)
                        ui.tab = .ask
                    } label: {
                        Card {
                            HStack {
                                Text(q).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "arrow.up.circle.fill").font(.title3).foregroundStyle(theme.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Data

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

    private func reload() async {
        let env = env
        guard let r = try? await env.db.writer.read({ db in try Self.fetch(db, now: env.clock.now, timeZone: env.timeZone) }),
              r != rows else { return }
        rows = r
        plan = r.plan.map(Self.obj) ?? [:]
        bouts = r.bouts.map(Self.obj).filter { ($0["label"] as? String) != "unknown" }
        day = r.day.map(Self.obj) ?? [:]
    }

    nonisolated static func fetch(_ db: Database, now: Date, timeZone: TimeZone) throws -> Rows {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let dayStart = cal.startOfDay(for: now).timeIntervalSince1970
        var r = Rows()
        r.plan = try String.fetchOne(db, sql: """
            SELECT value_json FROM inferences WHERE kind = 'wind_down_plan' AND superseded_by IS NULL
            ORDER BY json_extract(value_json, '$.night_of') DESC, id DESC LIMIT 1
            """)
        r.bouts = try String.fetchAll(db, sql: """
            SELECT value_json FROM inferences WHERE kind = 'activity_bout' AND superseded_by IS NULL
            AND minute_end > ? AND minute_start < ? ORDER BY minute_start DESC
            """, arguments: [Int(dayStart / 60), Int(now.timeIntervalSince1970 / 60)])
        r.day = try String.fetchOne(db, sql: """
            SELECT value_json FROM inferences WHERE kind = 'activity_day' AND superseded_by IS NULL
            AND minute_start = ? ORDER BY id DESC LIMIT 1
            """, arguments: [Int(dayStart / 60)])
        return r
    }

    nonisolated static func obj(_ s: String) -> [String: Any] {
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
            } footer: { Text("HealthBot also adjusts this from how long you take to fall asleep.") }
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
