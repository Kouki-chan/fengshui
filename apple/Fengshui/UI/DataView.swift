import Charts
import GRDB
import SwiftUI

/// Data tab: a compact view of what has reached this phone from Apple Health and the watch.
/// Driven by a GRDB ValueObservation, so every HealthKit sync (foreground, observer query,
/// background delivery) and every watch file import redraws it without a manual refresh.
struct DataSnapshot: Equatable, Sendable {
    struct Point: Equatable, Sendable { let ts: Double; let value: Double }

    struct Reading: Equatable, Sendable, Identifiable {
        var id: String { label }
        let label: String
        let value: Double
        let unit: String
        let ts: Double
        var series: [Point] = []
    }

    struct Total: Equatable, Sendable, Identifiable {
        var id: String { label }
        let label: String
        let value: Double
        let unit: String
    }

    struct Sleep: Equatable, Sendable {
        var asleep = 0.0, deep = 0.0, rem = 0.0, core = 0.0, awake = 0.0
        var isEmpty: Bool { asleep == 0 && awake == 0 }
    }

    struct Feature: Equatable, Sendable {
        let minuteID: Int
        let enmoMg: Double?
        let cadenceHz: Double?
    }

    struct Watch: Equatable, Sendable {
        var lastReceived: Double?
        var accelMinutes24h = 0
        /// Chunks received in the last 24 h, per sensor.
        var sensors: [String: Int] = [:]
        var latestFeature: Feature?
    }

    struct Recent: Equatable, Sendable, Identifiable {
        let id: Int64
        let label: String
        let value: Double?
        let text: String?
        let unit: String?
        let ts: Double
        let source: String?
    }

    var vitals: [Reading] = []
    var totals: [Total] = []
    var sleep = Sleep()
    var watch = Watch()
    var recent: [Recent] = []

    var isEmpty: Bool { vitals.isEmpty && totals.isEmpty && sleep.isEmpty && recent.isEmpty && watch.lastReceived == nil }

    static let vitalLabels = ["heart_rate", "resting_heart_rate", "heart_rate_variability_sdnn",
                              "oxygen_saturation", "respiratory_rate"]
    static let totalLabels = ["step_count", "active_energy_burned", "distance_walking_running",
                              "apple_exercise_time", "flights_climbed"]
    /// The HealthKit types polled while the Data tab is on screen.
    static let liveTypes = ["HKQuantityTypeIdentifierHeartRate", "HKQuantityTypeIdentifierStepCount",
                            "HKQuantityTypeIdentifierActiveEnergyBurned", "HKQuantityTypeIdentifierDistanceWalkingRunning",
                            "HKQuantityTypeIdentifierAppleExerciseTime", "HKQuantityTypeIdentifierRestingHeartRate",
                            "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", "HKQuantityTypeIdentifierOxygenSaturation",
                            "HKQuantityTypeIdentifierRespiratoryRate", "HKCategoryTypeIdentifierSleepAnalysis"]

    static func fetch(_ db: Database, now: Date, timeZone: TimeZone) throws -> DataSnapshot {
        var s = DataSnapshot()
        let nowTs = now.timeIntervalSince1970
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let dayStart = cal.startOfDay(for: now).timeIntervalSince1970

        for label in vitalLabels {
            guard let row = try Row.fetchOne(db, sql: """
                SELECT value, unit, end_ts FROM processed_samples
                WHERE label = ? AND deleted = 0 AND value IS NOT NULL ORDER BY start_ts DESC LIMIT 1
                """, arguments: [label]) else { continue }
            let (v, u) = normalize(label: label, value: row["value"], unit: row["unit"])
            // Heart rate: 30-min averages over 24 h; the slower vitals: daily averages over 14 days.
            let hr = label == "heart_rate"
            let points = try series(db, label: label, since: hr ? nowTs - 86_400 : nowTs - 14 * 86_400,
                                    bucket: hr ? 1_800 : 86_400, cumulative: false, timeZone: timeZone)
            s.vitals.append(Reading(label: label, value: v, unit: u, ts: row["end_ts"], series: points))
        }

        for label in totalLabels {
            // Per-source maximum, like the engine (DECISIONS D-14): watch + phone both count steps.
            guard let row = try Row.fetchOne(db, sql: """
                SELECT MAX(total) AS total, MAX(unit) AS unit FROM (
                  SELECT SUM(value) AS total, MAX(unit) AS unit FROM processed_samples
                  WHERE label = ? AND deleted = 0 AND start_ts >= ? AND start_ts < ?
                  GROUP BY COALESCE(source_bundle, source_name, ''))
                """, arguments: [label, dayStart, dayStart + 86_400]),
                let total = row["total"] as Double? else { continue }
            let (v, u) = normalize(label: label, value: total, unit: row["unit"])
            s.totals.append(Total(label: label, value: v, unit: u))
        }

        s.sleep = try sleep(db, dayStart: dayStart)

        let since = Int(nowTs / 60) - 1_440
        s.watch.lastReceived = try Double.fetchOne(db, sql: "SELECT MAX(received_at) FROM raw_chunks")
        s.watch.accelMinutes24h = try Int.fetchOne(db, sql: """
            SELECT COUNT(DISTINCT minute_id) FROM raw_chunks WHERE sensor = 'accel' AND minute_id >= ?
            """, arguments: [since]) ?? 0
        for row in try Row.fetchAll(db, sql: """
            SELECT sensor, COUNT(*) AS n FROM raw_chunks WHERE minute_id >= ? GROUP BY sensor
            """, arguments: [since]) {
            s.watch.sensors[row["sensor"]] = row["n"]
        }
        if let row = try Row.fetchOne(db, sql: """
            SELECT minute_id, enmo_mg, cadence_hz FROM raw_minute_features ORDER BY minute_id DESC LIMIT 1
            """) {
            s.watch.latestFeature = Feature(minuteID: row["minute_id"], enmoMg: row["enmo_mg"], cadenceHz: row["cadence_hz"])
        }

        // Newest rows by insertion: what the last sync actually brought in.
        s.recent = try Row.fetchAll(db, sql: """
            SELECT id, label, value, value_text, unit, end_ts, source_name FROM processed_samples
            WHERE deleted = 0 ORDER BY id DESC LIMIT 8
            """).map { r in
            let label: String = r["label"]
            let norm = (r["value"] as Double?).map { normalize(label: label, value: $0, unit: r["unit"]) }
            return Recent(id: r["id"], label: label, value: norm?.0, text: r["value_text"], unit: norm?.1 ?? r["unit"],
                          ts: r["end_ts"], source: r["source_name"])
        }
        return s
    }

    /// Last night: sleep stages that started between 18:00 yesterday and noon today,
    /// taking the source with the most sleep (watch and phone can both record it).
    static func sleep(_ db: Database, dayStart: Double) throws -> Sleep {
        var bySource: [String: Sleep] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT COALESCE(source_bundle, source_name, '') AS src, value_text, SUM(end_ts - start_ts) AS secs
            FROM processed_samples WHERE label = 'sleep_analysis' AND deleted = 0 AND start_ts >= ? AND start_ts < ?
            GROUP BY src, value_text
            """, arguments: [dayStart - 6 * 3_600, dayStart + 12 * 3_600]) {
            let src: String = row["src"]
            let secs: Double = row["secs"] ?? 0
            var s = bySource[src] ?? Sleep()
            switch row["value_text"] as String? {
            case "asleep_deep": s.deep += secs; s.asleep += secs
            case "asleep_rem": s.rem += secs; s.asleep += secs
            case "asleep_core": s.core += secs; s.asleep += secs
            case "asleep_unspecified": s.asleep += secs
            case "awake": s.awake += secs
            default: break
            }
            bySource[src] = s
        }
        return bySource.values.max { $0.asleep < $1.asleep } ?? Sleep()
    }

    /// Averages (or per-source-max sums for cumulative types) per bucket, in local time.
    static func series(_ db: Database, label: String, since: Double, bucket: Double, cumulative: Bool,
                       timeZone: TimeZone) throws -> [Point] {
        let offset = Double(timeZone.secondsFromGMT())
        // Convert per-second rates per row, so a bucket never averages two units.
        let perMinute = "CASE WHEN unit = 'count/s' THEN value * 60 ELSE value END"
        let unitExpr = "REPLACE(MAX(unit), 'count/s', 'count/min')"
        let sql = cumulative ? """
            SELECT b, MAX(v) AS v, MAX(unit) AS unit FROM (
              SELECT CAST((start_ts + ?) / ? AS INTEGER) AS b, SUM(\(perMinute)) AS v, \(unitExpr) AS unit
              FROM processed_samples WHERE label = ? AND deleted = 0 AND value IS NOT NULL AND start_ts >= ?
              GROUP BY b, COALESCE(source_bundle, source_name, ''))
            GROUP BY b ORDER BY b
            """ : """
            SELECT CAST((start_ts + ?) / ? AS INTEGER) AS b, AVG(\(perMinute)) AS v, \(unitExpr) AS unit
            FROM processed_samples WHERE label = ? AND deleted = 0 AND value IS NOT NULL AND start_ts >= ?
            GROUP BY b ORDER BY b
            """
        return try Row.fetchAll(db, sql: sql, arguments: [offset, bucket, label, since]).map { r in
            let b: Int = r["b"]
            let unit: String? = r["unit"]
            // Distances: always km in charts so every bucket shares one unit.
            let v: Double = unit == "m" ? r["v"] / 1_000 : normalize(label: label, value: r["v"], unit: unit).0
            return Point(ts: Double(b) * bucket - offset, value: v)
        }
    }

    /// HealthKit stores in the user's preferred unit; show the everyday one.
    static func normalize(label: String, value: Double, unit: String?) -> (Double, String) {
        let perMin = label.contains("heart_rate") ? "bpm" : "/min"
        switch unit ?? "" {
        case "count/s": return (value * 60, perMin)
        case "count/min": return (value, perMin)
        case "%": return (value <= 1 ? value * 100 : value, "%")
        case "m" where value >= 1_000: return (value / 1_000, "km")
        case "count": return (value, label == "step_count" ? "steps" : "")
        case "s": return (value / 60, "min")
        default: return (value, unit ?? "")
        }
    }

    static func title(_ label: String) -> String {
        let names = ["heart_rate": "Heart rate", "resting_heart_rate": "Resting HR",
                     "heart_rate_variability_sdnn": "HRV", "oxygen_saturation": "Blood oxygen",
                     "respiratory_rate": "Breathing", "step_count": "Steps", "active_energy_burned": "Active energy",
                     "distance_walking_running": "Distance", "apple_exercise_time": "Exercise",
                     "flights_climbed": "Flights", "sleep_analysis": "Sleep"]
        return names[label] ?? label.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func format(_ v: Double, unit: String) -> String {
        switch unit {
        case "km": return v.formatted(.number.precision(.fractionLength(1)))
        case "h", "kg": return v.formatted(.number.precision(.fractionLength(0...1)))
        default: return v.formatted(.number.precision(.fractionLength(v < 10 && v != v.rounded() ? 1 : 0)))
        }
    }

    static func cumulative(_ label: String) -> Bool {
        totalLabels.contains(label) || label.hasPrefix("distance_") || label.hasPrefix("dietary_")
            || ["basal_energy_burned", "apple_stand_time", "time_in_daylight", "number_of_times_fallen"].contains(label)
    }
}

/// "3 min ago" against the app clock (fixed in test mode).
func ago(_ ts: Double, now: Date) -> String {
    let secs = now.timeIntervalSince1970 - ts
    if secs < 45 { return "just now" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(fromTimeInterval: -secs)
}

func hm(_ secs: Double) -> String {
    let m = Int(secs / 60)
    return m >= 60 ? "\(m / 60) h \(m % 60) m" : "\(m) m"
}

/// The Data tab's state, owned by UIState so it survives tab switches: coming back to the tab
/// shows the last snapshot at once instead of re-reading everything on the main thread.
@MainActor
@Observable
final class DataModel {
    private(set) var snapshot = DataSnapshot()
    private(set) var loaded = false
    private(set) var updatedAt: Date?
    private(set) var live: LiveWatchReading?
    private let env: AppEnvironment
    private var lastFlush: Date?

    /// A HealthKit backfill or watch import commits many times a second; refetch at most this often.
    static let throttle: Duration = .seconds(1)
    static let pollInterval: Duration = .seconds(60)

    init(env: AppEnvironment) { self.env = env }

    /// While the tab is on screen: refetch when the tables the snapshot reads change. The cheap
    /// observation only signals; the snapshot is read off the main thread, coalesced and throttled.
    func observe() async {
        let signal = ValueObservation.tracking(region: Table("processed_samples"), Table("raw_chunks"),
                                               Table("raw_minute_features"), fetch: { _ in true })
        do {
            for try await _ in signal.values(in: env.db.writer, bufferingPolicy: .bufferingNewest(1)) {
                await refresh()
                try await Task.sleep(for: Self.throttle)
            }
        } catch {}
    }

    func refresh() async {
        let env = env
        do {
            let s = try await env.db.writer.read { db in try DataSnapshot.fetch(db, now: env.clock.now, timeZone: env.timeZone) }
            if s != snapshot { snapshot = s }
            loaded = true
            updatedAt = Date()
        } catch {
            env.log.add("data_view_error", "\(error)")
        }
    }

    /// While on screen: pull the fast-changing HealthKit types every minute (observer queries
    /// also fire on their own) and ask the watch for its latest file (at most once a minute).
    func pollWhileVisible() async {
        flushWatch()
        live = env.watchLink.live
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pollInterval)
            if Task.isCancelled { break }
            await env.syncLiveTypes()
            await refresh()
        }
    }

    func pull() async {
        flushWatch(force: true)
        await env.syncLiveTypes()
        await refresh()
    }

    func liveChanged() { live = env.watchLink.live }

    func flushWatch(force: Bool = false) {
        if !force, let lastFlush, Date().timeIntervalSince(lastFlush) < 60 { return }
        lastFlush = Date()
        env.watchLink.requestFlush()
    }
}

struct DataView: View {
    let env: AppEnvironment
    let model: DataModel
    @Environment(\.theme) private var theme

    private let grid = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        let snapshot = model.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                status
                if let live = model.live, env.clock.now.timeIntervalSince1970 - live.ts < 30 { liveCard(live) }
                if model.loaded && snapshot.isEmpty {
                    Card {
                        ContentUnavailableView("No data yet", systemImage: "heart.text.square",
                                               description: Text("Allow HealthBot to read Health data: Settings → Privacy & Security → Health → HealthBot → Turn On All."))
                    }
                    .accessibilityIdentifier("data.empty")
                }
                if !snapshot.vitals.isEmpty { vitals(snapshot) }
                if !snapshot.totals.isEmpty { today(snapshot) }
                if !snapshot.sleep.isEmpty { sleep(snapshot.sleep) }
                watch(snapshot.watch)
                if !snapshot.recent.isEmpty { recent(snapshot.recent) }
                NavigationLink { DataTypesView(env: env) } label: {
                    Card {
                        HStack(spacing: 12) {
                            IconBadge(systemImage: "list.bullet", tint: theme.tint)
                            Text("All data types").font(.body.weight(.medium))
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("data.allTypes")
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 28)
        }
        .themedBackground()
        .navigationTitle("Data")
        .refreshable { await model.pull() }
        .task { await model.observe() }
        .task { await model.pollWhileVisible() }
        .onReceive(Foundation.NotificationCenter.default.publisher(for: .watchLive)) { _ in model.liveChanged() }
    }

    // MARK: Sections

    private var status: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            HStack(spacing: 6) {
                Circle().fill(model.updatedAt == nil ? Color.secondary : theme.activity).frame(width: 7, height: 7)
                Text(model.updatedAt.map { "Live · updated \(ago($0.timeIntervalSince1970, now: Date()))" } ?? "Connecting…")
                Spacer()
                Label(env.watchLink.isReachable ? "Watch connected" : "Watch not in range", systemImage: "applewatch")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("data.status")
    }

    private func liveCard(_ r: LiveWatchReading) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "heart.fill").font(.title2).symbolEffect(.pulse)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(r.heartRate.rounded()))").font(.largeTitle.weight(.bold)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text("bpm").font(.headline)
                }
                Text("Live from your watch session").font(.caption).opacity(0.85)
            }
            Spacer()
        }
        .foregroundStyle(theme.onHero)
        .padding(16)
        .background(theme.heroGradient, in: .rect(cornerRadius: 22, style: .continuous))
        .accessibilityIdentifier("data.liveHR")
    }

    private func vitals(_ s: DataSnapshot) -> some View {
        CardSection(title: "Vitals", systemImage: "heart.fill", tint: theme.heart) {
            LazyVGrid(columns: grid, spacing: 10) {
                ForEach(s.vitals) { r in
                    NavigationLink { DataTypeDetailView(env: env, label: r.label) } label: {
                        StatTile(title: DataSnapshot.title(r.label), value: DataSnapshot.format(r.value, unit: r.unit),
                                 unit: r.unit, caption: ago(r.ts, now: env.clock.now), systemImage: DataSnapshot.icon(r.label),
                                 series: r.series, tint: theme.color(for: r.label))
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("data.vital.\(r.label)")
                }
            }
        }
    }

    private func today(_ s: DataSnapshot) -> some View {
        CardSection(title: "Today", systemImage: "figure.walk", tint: theme.activity) {
            LazyVGrid(columns: grid, spacing: 10) {
                ForEach(s.totals) { t in
                    NavigationLink { DataTypeDetailView(env: env, label: t.label) } label: {
                        StatTile(title: DataSnapshot.title(t.label), value: DataSnapshot.format(t.value, unit: t.unit),
                                 unit: t.unit, caption: "since midnight", systemImage: DataSnapshot.icon(t.label),
                                 tint: theme.activity)
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("data.total.\(t.label)")
                }
            }
        }
    }

    private func sleep(_ s: DataSnapshot.Sleep) -> some View {
        CardSection(title: "Last night", systemImage: "moon.zzz.fill", tint: theme.sleep) {
            NavigationLink { DataTypeDetailView(env: env, label: "sleep_analysis") } label: {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(hm(s.asleep)).font(.title2.weight(.semibold)).monospacedDigit()
                            Text("asleep").font(.caption).foregroundStyle(.secondary)
                        }
                        SleepBar(sleep: s, tint: theme.sleep).frame(height: 12)
                        HStack(spacing: 0) {
                            stat("Deep", hm(s.deep), theme.sleep)
                            stat("Core", hm(s.core), theme.sleep.opacity(0.6))
                            stat("REM", hm(s.rem), theme.sleep.opacity(0.35))
                            stat("Awake", hm(s.awake), Color(.systemGray3))
                        }
                    }
                }
            }
            .buttonStyle(.plain).accessibilityIdentifier("data.sleep")
        }
    }

    private func watch(_ w: DataSnapshot.Watch) -> some View {
        CardSection(title: "Watch sensors", systemImage: "applewatch", tint: theme.tint) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Last data from watch", value: w.lastReceived.map { ago($0, now: env.clock.now) } ?? "none yet")
                    VStack(alignment: .leading, spacing: 4) {
                        let pct = min(100, w.accelMinutes24h * 100 / 1_440)
                        LabeledContent("Accelerometer, 24 h", value: "\(pct) % of minutes")
                        ProgressView(value: Double(pct), total: 100).tint(theme.tint)
                    }
                    if let f = w.latestFeature {
                        LabeledContent("Latest movement") {
                            Text([f.enmoMg.map { "\(Int($0)) mg" }, f.cadenceHz.flatMap { $0 > 0 ? "\(Int($0 * 60)) steps/min" : nil }]
                                .compactMap { $0 }.joined(separator: " · ") + " · " + ago(Double(f.minuteID * 60), now: env.clock.now))
                        }
                    }
                    let snaps = ["gyro", "baro", "compass", "hr_session"].compactMap { k in
                        w.sensors[k].map { "\(k.replacingOccurrences(of: "_session", with: "")) \($0)" }
                    }
                    if !snaps.isEmpty { LabeledContent("Snapshots, 24 h", value: snaps.joined(separator: " · ")) }
                    Button { model.flushWatch(force: true) } label: {
                        Label("Ask watch to send now", systemImage: "applewatch.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!env.watchLink.isReachable)
                    .accessibilityIdentifier("data.flushWatch")
                    if !env.watchLink.isReachable {
                        Text("Open HealthBot on the watch to send now. Otherwise it sends about once an hour.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("data.watch")
        }
    }

    private func recent(_ rows: [DataSnapshot.Recent]) -> some View {
        CardSection(title: "Just received", systemImage: "arrow.down.circle", tint: theme.tint) {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Divider().padding(.leading, 52) }
                        HStack(spacing: 12) {
                            IconBadge(systemImage: DataSnapshot.icon(r.label), tint: theme.color(for: r.label), size: 28)
                            Text(DataSnapshot.title(r.label)).lineLimit(1)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(r.value.map { "\(DataSnapshot.format($0, unit: r.unit ?? "")) \(r.unit ?? "")" }
                                     ?? (r.text ?? "").replacingOccurrences(of: "_", with: " "))
                                    .monospacedDigit()
                                Text(ago(r.ts, now: env.clock.now)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .font(.footnote).padding(.horizontal, 12).padding(.vertical, 9)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("data.recent")
        }
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Last night's stages as one rounded bar: deep, core, REM, awake.
struct SleepBar: View {
    let sleep: DataSnapshot.Sleep
    let tint: Color

    var body: some View {
        let parts: [(Double, Color)] = [(sleep.deep, tint), (sleep.core, tint.opacity(0.6)), (sleep.rem, tint.opacity(0.35)),
                                        (sleep.awake, Color(.systemGray3))]
        // Watches that only record "asleep" have no stages: show it as one block.
        let staged = sleep.deep + sleep.core + sleep.rem
        let shown = staged > 0 ? parts : [(sleep.asleep, tint.opacity(0.6)), (sleep.awake, Color(.systemGray3))]
        let total = max(shown.map(\.0).reduce(0, +), 1)
        GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, p in
                    if p.0 > 0 { Rectangle().fill(p.1).frame(width: max(2, (g.size.width - 6) * p.0 / total)) }
                }
            }
        }
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }
}

extension DataSnapshot {
    static func icon(_ label: String) -> String {
        let icons = ["heart_rate": "heart.fill", "resting_heart_rate": "heart.circle", "heart_rate_variability_sdnn": "waveform.path.ecg",
                     "oxygen_saturation": "drop.fill", "respiratory_rate": "lungs.fill", "step_count": "figure.walk",
                     "active_energy_burned": "flame.fill", "distance_walking_running": "map.fill", "apple_exercise_time": "figure.run",
                     "flights_climbed": "figure.stairs", "sleep_analysis": "bed.double.fill", "workout": "dumbbell.fill"]
        return icons[label] ?? "chart.xyaxis.line"
    }
}

extension Theme {
    /// One colour per data family, so a label looks the same on every screen.
    func color(for label: String) -> Color {
        if label.contains("heart") || label == "oxygen_saturation" || label == "respiratory_rate" { return heart }
        if label.hasPrefix("sleep") || label.contains("mindful") { return sleep }
        return activity
    }
}

/// Every label in the database with its count and newest sample.
struct DataTypesView: View {
    struct Row: Sendable, Identifiable {
        var id: String { label }
        let label: String
        let count: Int
        let latest: Double?
    }

    let env: AppEnvironment
    @State private var rows: [Row] = []
    @State private var loading = true
    @State private var query = ""

    var body: some View {
        List(rows.filter { query.isEmpty || DataSnapshot.title($0.label).localizedCaseInsensitiveContains(query) }) { r in
            NavigationLink { DataTypeDetailView(env: env, label: r.label) } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(DataSnapshot.title(r.label)).font(.subheadline)
                        Text(r.latest.map { "latest \(ago($0, now: env.clock.now))" } ?? "").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(r.count.formatted()).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("data.type.\(r.label)")
        }
        .overlay { if loading { ProgressView() } else if rows.isEmpty { ContentUnavailableView("No data yet", systemImage: "tray") } }
        .themedList()
        .searchable(text: $query)
        .navigationTitle("All data types")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        rows = (try? await env.db.writer.read { db in
            try GRDB.Row.fetchAll(db, sql: """
                SELECT label, COUNT(*) AS n, MAX(end_ts) AS latest FROM processed_samples
                WHERE deleted = 0 GROUP BY label ORDER BY label
                """).map { Row(label: $0["label"], count: $0["n"], latest: $0["latest"]) }
        }) ?? []
        loading = false
    }
}

/// One label: a 7-day chart (hourly averages, or daily totals for cumulative types) and the
/// newest 100 samples. Live, like the Data tab.
struct DataTypeDetailView: View {
    struct Detail: Equatable, Sendable {
        var points: [DataSnapshot.Point] = []
        var unit = ""
        var samples: [DataSnapshot.Recent] = []
    }

    let env: AppEnvironment
    let label: String
    @Environment(\.theme) private var theme
    @State private var detail = Detail()

    var body: some View {
        let cumulative = DataSnapshot.cumulative(label)
        List {
            if detail.points.count > 1 {
                Section(cumulative ? "Daily total, 14 days" : "Hourly average, 7 days") {
                    Chart(detail.points, id: \.ts) { p in
                        if cumulative {
                            BarMark(x: .value("Day", Date(timeIntervalSince1970: p.ts), unit: .day), y: .value(detail.unit, p.value))
                        } else {
                            LineMark(x: .value("Time", Date(timeIntervalSince1970: p.ts)), y: .value(detail.unit, p.value))
                                .interpolationMethod(.monotone)
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: cumulative))
                    .foregroundStyle(theme.color(for: label))
                    .frame(height: 180)
                    .accessibilityIdentifier("data.detail.chart")
                }
            }
            Section("Newest samples") {
                ForEach(detail.samples) { r in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(Date(timeIntervalSince1970: r.ts).formatted(date: .abbreviated, time: .shortened)).font(.footnote)
                            if let s = r.source { Text(s).font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text(r.value.map { "\(DataSnapshot.format($0, unit: r.unit ?? "")) \(r.unit ?? "")" }
                             ?? (r.text ?? "–").replacingOccurrences(of: "_", with: " "))
                            .font(.footnote).monospacedDigit()
                    }
                }
                if detail.samples.isEmpty { Text("No samples").foregroundStyle(.secondary) }
            }
        }
        .themedList()
        .navigationTitle(DataSnapshot.title(label))
        .task { await observe() }
    }

    private func observe() async {
        let observation = ValueObservation.tracking { [env, label] db in
            try Self.fetch(db, label: label, now: env.clock.now, timeZone: env.timeZone)
        }.removeDuplicates()
        do {
            for try await d in observation.values(in: env.db.writer) { detail = d }
        } catch {
            env.log.add("data_detail_error", "\(error)")
        }
    }

    nonisolated static func fetch(_ db: Database, label: String, now: Date, timeZone: TimeZone) throws -> Detail {
        var d = Detail()
        let cumulative = DataSnapshot.cumulative(label)
        let nowTs = now.timeIntervalSince1970
        d.points = try DataSnapshot.series(db, label: label, since: nowTs - (cumulative ? 14 : 7) * 86_400,
                                           bucket: cumulative ? 86_400 : 3_600, cumulative: cumulative, timeZone: timeZone)
        d.samples = try GRDB.Row.fetchAll(db, sql: """
            SELECT id, value, value_text, unit, start_ts, source_name FROM processed_samples
            WHERE label = ? AND deleted = 0 ORDER BY start_ts DESC LIMIT 100
            """, arguments: [label]).map { r in
            let norm = (r["value"] as Double?).map { DataSnapshot.normalize(label: label, value: $0, unit: r["unit"]) }
            return DataSnapshot.Recent(id: r["id"], label: label, value: norm?.0, text: r["value_text"],
                                       unit: norm?.1 ?? r["unit"], ts: r["start_ts"], source: r["source_name"])
        }
        d.unit = d.samples.first.map { $0.unit == "m" ? "km" : $0.unit ?? "" } ?? ""
        return d
    }
}
