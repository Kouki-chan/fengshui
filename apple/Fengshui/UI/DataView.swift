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

struct DataView: View {
    let env: AppEnvironment
    @State private var snapshot = DataSnapshot()
    @State private var loaded = false
    @State private var updatedAt: Date?
    @State private var live: LiveWatchReading?
    /// Bumped every minute so "today" and the 24-h windows move even when nothing is written.
    @State private var tick = 0

    static let pollInterval: Duration = .seconds(60)
    private let grid = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                status
                if let live, env.clock.now.timeIntervalSince1970 - live.ts < 30 { liveCard(live) }
                if loaded && snapshot.isEmpty {
                    ContentUnavailableView("No data yet", systemImage: "heart.text.square",
                                           description: Text("Allow Fengshui to read Health data: Settings → Privacy & Security → Health → Fengshui → Turn On All."))
                        .accessibilityIdentifier("data.empty")
                }
                if !snapshot.vitals.isEmpty { vitals }
                if !snapshot.totals.isEmpty { today }
                if !snapshot.sleep.isEmpty { sleep }
                watch
                if !snapshot.recent.isEmpty { recent }
                NavigationLink { DataTypesView(env: env) } label: {
                    Label("All data types", systemImage: "list.bullet").frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12).background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                .accessibilityIdentifier("data.allTypes")
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Data")
        .refreshable { await pull() }
        .task(id: tick) { await observe() }
        .task { await pollWhileVisible() }
        .onReceive(Foundation.NotificationCenter.default.publisher(for: .watchLive)) { _ in live = env.watchLink.live }
    }

    // MARK: Sections

    private var status: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text(updatedAt.map { "Live · updated \(ago($0.timeIntervalSince1970, now: Date()))" } ?? "Connecting…")
                Spacer()
                Text(env.watchLink.isReachable ? "Watch connected" : "Watch not in range")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("data.status")
    }

    private func liveCard(_ r: LiveWatchReading) -> some View {
        HStack {
            Image(systemName: "heart.fill").foregroundStyle(.red).symbolEffect(.pulse)
            Text("\(Int(r.heartRate.rounded()))").font(.title2.weight(.semibold)).monospacedDigit()
            Text("bpm · live from watch session").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12).background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        .accessibilityIdentifier("data.liveHR")
    }

    private var vitals: some View {
        section("Vitals") {
            LazyVGrid(columns: grid, spacing: 8) {
                ForEach(snapshot.vitals) { r in
                    NavigationLink { DataTypeDetailView(env: env, label: r.label) } label: {
                        Tile(title: DataSnapshot.title(r.label), value: DataSnapshot.format(r.value, unit: r.unit),
                             unit: r.unit, caption: ago(r.ts, now: env.clock.now), series: r.series,
                             tint: r.label.contains("heart") ? .red : .blue)
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("data.vital.\(r.label)")
                }
            }
        }
    }

    private var today: some View {
        section("Today") {
            LazyVGrid(columns: grid, spacing: 8) {
                ForEach(snapshot.totals) { t in
                    NavigationLink { DataTypeDetailView(env: env, label: t.label) } label: {
                        Tile(title: DataSnapshot.title(t.label), value: DataSnapshot.format(t.value, unit: t.unit),
                             unit: t.unit, caption: "since midnight", tint: .orange)
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("data.total.\(t.label)")
                }
            }
        }
    }

    private var sleep: some View {
        let s = snapshot.sleep
        return section("Last night") {
            NavigationLink { DataTypeDetailView(env: env, label: "sleep_analysis") } label: {
                HStack(spacing: 0) {
                    stat("Asleep", hm(s.asleep))
                    stat("Deep", hm(s.deep))
                    stat("REM", hm(s.rem))
                    stat("Awake", hm(s.awake))
                }
                .padding(12).background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
            }
            .buttonStyle(.plain).accessibilityIdentifier("data.sleep")
        }
    }

    private var watch: some View {
        let w = snapshot.watch
        return section("Watch sensors") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Last data from watch", value: w.lastReceived.map { ago($0, now: env.clock.now) } ?? "none yet")
                LabeledContent("Accelerometer, 24 h", value: "\(min(100, w.accelMinutes24h * 100 / 1_440)) % of minutes")
                if let f = w.latestFeature {
                    LabeledContent("Latest movement") {
                        Text([f.enmoMg.map { "\(Int($0)) mg" }, f.cadenceHz.flatMap { $0 > 0 ? "\(Int($0 * 60)) steps/min" : nil }]
                            .compactMap { $0 }.joined(separator: " · ") + " · " + ago(Double(f.minuteID * 60), now: env.clock.now))
                    }
                }
                let snaps = ["gyro", "baro", "compass", "hr_session"].compactMap { k in w.sensors[k].map { "\(k.replacingOccurrences(of: "_session", with: "")) \($0)" } }
                if !snaps.isEmpty { LabeledContent("Snapshots, 24 h", value: snaps.joined(separator: " · ")) }
                Button {
                    env.watchLink.requestFlush()
                } label: {
                    Label("Ask watch to send now", systemImage: "applewatch.radiowaves.left.and.right")
                }
                .disabled(!env.watchLink.isReachable)
                .accessibilityIdentifier("data.flushWatch")
                if !env.watchLink.isReachable {
                    Text("Open Fengshui on the watch to send now. Otherwise it sends about once an hour.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .padding(12).background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
            .accessibilityIdentifier("data.watch")
        }
    }

    private var recent: some View {
        section("Just received") {
            VStack(spacing: 0) {
                ForEach(Array(snapshot.recent.enumerated()), id: \.element.id) { i, r in
                    if i > 0 { Divider() }
                    HStack {
                        Text(DataSnapshot.title(r.label)).lineLimit(1)
                        Spacer()
                        Text(r.value.map { "\(DataSnapshot.format($0, unit: r.unit ?? "")) \(r.unit ?? "")" }
                             ?? (r.text ?? "").replacingOccurrences(of: "_", with: " "))
                            .monospacedDigit()
                        Text(ago(r.ts, now: env.clock.now)).foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
                    }
                    .font(.footnote).padding(.vertical, 7)
                }
            }
            .padding(.horizontal, 12).background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
            .accessibilityIdentifier("data.recent")
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Live updates

    /// Redraws on every commit that touches the tables read by `DataSnapshot.fetch`.
    private func observe() async {
        let observation = ValueObservation.tracking { [env] db in
            try DataSnapshot.fetch(db, now: env.clock.now, timeZone: env.timeZone)
        }.removeDuplicates()
        do {
            for try await s in observation.values(in: env.db.writer) {
                snapshot = s
                loaded = true
                updatedAt = Date()
            }
        } catch {
            env.log.add("data_view_error", "\(error)")
        }
    }

    /// While on screen: pull the fast-changing HealthKit types every minute (observer queries
    /// also fire on their own) and ask the watch for its latest file.
    private func pollWhileVisible() async {
        env.watchLink.requestFlush()
        live = env.watchLink.live
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pollInterval)
            if Task.isCancelled { break }
            await syncLiveTypes()
            tick += 1
        }
    }

    private func pull() async {
        env.watchLink.requestFlush()
        await syncLiveTypes()
        tick += 1
    }

    private func syncLiveTypes() async {
        // Never race the onboarding backfill: it owns the anchors until it's done.
        guard (try? await env.healthSync.backfillDone()) == true else { return }
        for id in DataSnapshot.liveTypes {
            guard let t = HealthTypeCatalog.info(id) else { continue }
            do {
                let n = try await env.healthSync.sync(t)
                if n > 0 { env.log.add("live_sync", "\(t.label) +\(n)") }
            } catch {
                env.log.add("live_sync_error", "\(t.label): \(error)")
            }
        }
    }
}

struct Tile: View {
    let title: String
    let value: String
    let unit: String
    let caption: String
    var series: [DataSnapshot.Point] = []
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            if series.count > 1 {
                Chart(series, id: \.ts) { p in
                    LineMark(x: .value("Time", Date(timeIntervalSince1970: p.ts)), y: .value("Value", p.value))
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .foregroundStyle(tint).frame(height: 22)
            }
            Text(caption).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
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
                    .frame(height: 160)
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
