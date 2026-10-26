import Foundation
import GRDB

/// What one report covers: period, labels and the text around the data (DECISIONS D-20).
struct ReportRequest: Sendable, Equatable {
    enum Kind: String, Sendable { case report, question }
    var kind: Kind = .report
    var title: String
    var purpose: String?
    /// Local dates YYYY-MM-DD, inclusive.
    var startDate: String
    var endDate: String
    var labels: [String]
    /// AI-written summary for the professional (nil for a data-only report).
    var summary: String?
    var question: String?
    var aiLogID: Int64?
}

/// One label's data in the report, already in everyday units.
struct ReportSection: Sendable, Equatable {
    enum Kind: String, Sendable { case numeric, cumulative, sleep, category, workout }
    struct Night: Sendable, Equatable { var date: String; var asleep, deep, rem, awake: Double }
    struct Count: Sendable, Equatable { var text: String; var n: Int }
    struct Workout: Sendable, Equatable { var ts: Double; var type: String; var minutes: Double }

    var label: String
    var title: String
    var group: String
    var unit: String
    var kind: Kind
    var count = 0
    var mean: Double?
    var min: Double?
    var max: Double?
    /// Cumulative types: total over the period; mean/min/max are per day.
    var total: Double?
    var daily: [DataSnapshot.Point] = []
    var nights: [Night] = []
    var categories: [Count] = []
    var workouts: [Workout] = []
    var sources: [String] = []

    var isEmpty: Bool { count == 0 && nights.isEmpty }
}

enum ReportData {
    static let groups: [(name: String, test: @Sendable (String) -> Bool)] = [
        ("Vitals", { ["heart_rate", "resting_heart_rate", "walking_heart_rate_average", "heart_rate_variability_sdnn",
                      "oxygen_saturation", "respiratory_rate", "blood_pressure_systolic", "blood_pressure_diastolic",
                      "body_temperature", "apple_sleeping_wrist_temperature", "vo2_max",
                      "heart_rate_recovery_one_minute", "blood_glucose"].contains($0) }),
        ("Sleep", { $0 == "sleep_analysis" || $0.hasPrefix("sleeping_") || $0 == "apple_sleeping_breathing_disturbances" }),
        ("Activity", { $0 == "workout" || $0 == "step_count" || $0.hasPrefix("distance_") || $0.hasSuffix("_energy_burned")
            || $0.hasPrefix("apple_exercise") || $0.hasPrefix("apple_stand") || $0 == "flights_climbed"
            || $0.hasPrefix("walking_") || $0.hasPrefix("running_") || $0 == "physical_effort" }),
        ("Events", { $0.hasSuffix("_event") }),
        ("Body", { ["body_mass", "body_mass_index", "height", "body_fat_percentage", "lean_body_mass",
                    "waist_circumference"].contains($0) }),
        ("Mind", { $0 == "state_of_mind" || $0 == "mindful_session" }),
        ("Nutrition", { $0.hasPrefix("dietary_") }),
    ]

    static func group(_ label: String) -> String { groups.first { $0.test(label) }?.name ?? "Other" }
    static let groupOrder = groups.map(\.name) + ["Other"]

    struct Available: Sendable, Equatable, Identifiable {
        var id: String { label }
        var label: String
        var title: String
        var group: String
        var rows: Int
        var first: Double
        var last: Double
        var unit: String?
    }

    /// Labels with data in [start, end): what a report over this period can include.
    static func available(_ db: Database, range: (Double, Double)) throws -> [Available] {
        try Row.fetchAll(db, sql: """
            SELECT label, COUNT(*) AS n, MIN(start_ts) AS lo, MAX(start_ts) AS hi, MAX(unit) AS unit
            FROM processed_samples WHERE deleted = 0 AND start_ts >= ? AND start_ts < ? GROUP BY label
            """, arguments: [range.0, range.1]).map {
            let label: String = $0["label"]
            return Available(label: label, title: DataSnapshot.title(label), group: group(label), rows: $0["n"],
                             first: $0["lo"], last: $0["hi"], unit: $0["unit"])
        }
        .sorted { (groupOrder.firstIndex(of: $0.group) ?? 99, $0.title) < (groupOrder.firstIndex(of: $1.group) ?? 99, $1.title) }
    }

    /// Local day bounds for YYYY-MM-DD dates, end exclusive.
    static func range(start: String, end: String, timeZone: TimeZone) -> (Double, Double)? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let a = f.date(from: start), let b = f.date(from: end), b >= a else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return (cal.startOfDay(for: a).timeIntervalSince1970,
                cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: b))!.timeIntervalSince1970)
    }

    static func dayString(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = tz
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func sections(_ db: Database, labels: [String], range: (Double, Double), timeZone: TimeZone) throws -> [ReportSection] {
        let order = { (l: String) in (groupOrder.firstIndex(of: group(l)) ?? 99, DataSnapshot.title(l)) }
        return try labels.sorted { order($0) < order($1) }.map { try section(db, label: $0, range: range, timeZone: timeZone) }
    }

    static func section(_ db: Database, label: String, range: (Double, Double), timeZone: TimeZone) throws -> ReportSection {
        var s = ReportSection(label: label, title: DataSnapshot.title(label), group: group(label), unit: "", kind: .numeric)
        let args: StatementArguments = [label, range.0, range.1]
        let base = "FROM processed_samples WHERE label = ? AND deleted = 0 AND start_ts >= ? AND start_ts < ?"
        s.sources = try String.fetchAll(db, sql: "SELECT DISTINCT COALESCE(source_name, 'unknown') \(base) LIMIT 6", arguments: args)
        let numeric = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS n, COUNT(value) AS nv, MAX(unit) AS unit,
                   AVG(CASE WHEN unit = 'count/s' THEN value * 60 ELSE value END) AS mean,
                   MIN(CASE WHEN unit = 'count/s' THEN value * 60 ELSE value END) AS lo,
                   MAX(CASE WHEN unit = 'count/s' THEN value * 60 ELSE value END) AS hi \(base)
            """, arguments: args)
        s.count = numeric?["n"] ?? 0
        let unit: String? = numeric?["unit"]

        if label == "sleep_analysis" {
            s.kind = .sleep
            s.unit = "h"
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            var day = range.0
            while day < range.1 {
                let n = try DataSnapshot.sleep(db, dayStart: day)
                if !n.isEmpty {
                    s.nights.append(.init(date: dayString(Date(timeIntervalSince1970: day), timeZone), asleep: n.asleep,
                                          deep: n.deep, rem: n.rem, awake: n.awake))
                }
                day = cal.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: day))!.timeIntervalSince1970
            }
            let hours = s.nights.map { $0.asleep / 3600 }
            if !hours.isEmpty {
                s.mean = hours.reduce(0, +) / Double(hours.count)
                s.min = hours.min()
                s.max = hours.max()
            }
            s.daily = s.nights.compactMap { n in
                ReportData.range(start: n.date, end: n.date, timeZone: timeZone).map { .init(ts: $0.0, value: n.asleep / 3600) }
            }
            return s
        }
        if label == "workout" {
            s.kind = .workout
            s.unit = "min"
            s.workouts = try Row.fetchAll(db, sql: "SELECT start_ts, end_ts, value, unit, value_text \(base) ORDER BY start_ts LIMIT 200",
                                          arguments: args).map {
                let start: Double = $0["start_ts"], end: Double = $0["end_ts"]
                let secs = ($0["unit"] as String?) == "s" ? (($0["value"] as Double?) ?? end - start) : end - start
                let type = (($0["value_text"] as String?) ?? "workout").replacingOccurrences(of: "_", with: " ")
                return .init(ts: start, type: type.prefix(1).uppercased() + type.dropFirst(), minutes: secs / 60)
            }
            let mins = s.workouts.map(\.minutes)
            if !mins.isEmpty { s.total = mins.reduce(0, +); s.mean = s.total! / Double(mins.count) }
            return s
        }
        if (numeric?["nv"] as Int? ?? 0) == 0 {
            s.kind = .category
            s.categories = try Row.fetchAll(db, sql: """
                SELECT COALESCE(value_text, 'event') AS t, COUNT(*) AS n \(base) GROUP BY t ORDER BY n DESC LIMIT 8
                """, arguments: args).map { .init(text: ($0["t"] as String).replacingOccurrences(of: "_", with: " "), n: $0["n"]) }
            return s
        }
        let cumulative = DataSnapshot.cumulative(label)
        s.kind = cumulative ? .cumulative : .numeric
        s.daily = try DataSnapshot.series(db, label: label, since: range.0, bucket: 86_400, cumulative: cumulative,
                                          timeZone: timeZone).filter { $0.ts < range.1 }
        let perMin = unit == "count/s" ? "count/min" : unit
        s.unit = unit == "m" ? "km" : DataSnapshot.normalize(label: label, value: 0, unit: perMin).1
        let norm = { (v: Double?) in v.map { unit == "m" ? $0 / 1_000 : DataSnapshot.normalize(label: label, value: $0, unit: perMin).0 } }
        if cumulative {
            let days = s.daily.map(\.value)
            s.total = days.reduce(0, +)
            s.mean = days.isEmpty ? nil : s.total! / Double(days.count)
            s.min = days.min()
            s.max = days.max()
        } else {
            s.mean = norm(numeric?["mean"])
            s.min = norm(numeric?["lo"])
            s.max = norm(numeric?["hi"])
        }
        return s
    }
}
