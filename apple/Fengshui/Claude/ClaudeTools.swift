import FengshuiKit
import Foundation
import GRDB

/// The tools Claude may call (spec §13): read-only queries over processed iPhone data and
/// inferences, returning compact JSON. **No tool can read raw watch data**: every query goes
/// through `ReadOnlyQuery`, which refuses SQL naming a raw table and opens the DB read-only.
struct ClaudeTools: Sendable {
    static let rawTables = ["raw_chunks", "raw_minute_features"]
    /// Per tool result; the loop also caps the total per question (ClaudeAssistant).
    static let maxResultChars = 12_000
    static let maxRows = 300
    static let maxBuckets = 400

    let query: ReadOnlyQuery
    let timeZone: TimeZone
    let dbPath: String
    let python: EmbeddedPython

    init(dbPath: String, timeZone: TimeZone, python: EmbeddedPython = .shared) throws {
        query = try ReadOnlyQuery(path: dbPath)
        self.timeZone = timeZone
        self.dbPath = dbPath
        self.python = python
    }

    // MARK: Definitions sent to the API

    static var definitions: [[String: Any]] {
        func tool(_ name: String, _ desc: String, _ props: [String: [String: Any]], _ required: [String]) -> [String: Any] {
            ["name": name, "description": desc, "strict": true,
             "input_schema": ["type": "object", "properties": props, "required": required, "additionalProperties": false]]
        }
        let date = ["type": "string", "description": "Local date YYYY-MM-DD"]
        return [
            tool("list_available_data", "Lists which processed data labels exist with their date ranges and row counts, and which inference kinds exist. Call this first when unsure what data is available.", [:], []),
            tool("get_inferences", "Engine inferences of one kind (current rows only) between two local dates, inclusive. Kinds: activity_bout, activity_day, wind_down_plan, wind_down_outcome.",
                 ["kind": ["type": "string", "enum": ["activity_bout", "activity_day", "wind_down_plan", "wind_down_outcome"]],
                  "start": date, "end": date], ["kind", "start", "end"]),
            tool("get_daily_summary", "One local day: last night's sleep, activity summary, places visited, Screen Time threshold events, and the wind-down plan and outcome.",
                 ["date": date], ["date"]),
            tool("get_series", "A HealthKit series (label such as heart_rate, step_count, resting_heart_rate) aggregated into time buckets between two local dates, inclusive.",
                 ["label": ["type": "string"], "start": date, "end": date,
                  "bucket": ["type": "string", "enum": ["5m", "15m", "1h", "1d"]],
                  "agg": ["type": "string", "enum": ["avg", "sum", "min", "max"]]],
                 ["label", "start", "end", "bucket", "agg"]),
            tool("get_sleep_nights", "Main sleep per night between two local dates (by wake date): onset, wake, minutes asleep, stage minutes, sleep latency.",
                 ["start": date, "end": date], ["start", "end"]),
            tool("get_visits", "Visits to places (named, or unnamed) with arrival, departure and duration, between two local dates.",
                 ["start": date, "end": date], ["start", "end"]),
            tool("get_screen_events", "Screen Time threshold crossings (daily / evening schedules) between two local dates. Empty until Screen Time is enabled.",
                 ["start": date, "end": date], ["start", "end"]),
            // Reports for health professionals (DECISIONS D-20).
            tool("list_report_labels", "Which data labels have samples between two local dates, inclusive, grouped (Vitals, Sleep, Activity, Events, Body, Mind, Nutrition, Other) with row counts and units. Call this before choosing labels for a report.",
                 ["start": date, "end": date], ["start", "end"]),
            tool("propose_report_labels", "Propose the labels a report should include, with one short reason each. Used when the app asks you to suggest labels; the user reviews them before the report is made.",
                 ["labels": ["type": "array", "items": ["type": "string"]],
                  "reasons": ["type": "array", "items": ["type": "string"], "description": "One reason per label, same order"]],
                 ["labels", "reasons"]),
            tool("create_report", "Create a shareable PDF report for a health professional: the summary you write, then charts and tables for each label over the period. Returns the report id and page count.",
                 ["title": ["type": "string"], "start": date, "end": date,
                  "labels": ["type": "array", "items": ["type": "string"]],
                  "summary": ["type": "string", "description": "Plain text for a clinician: period, data used, averages and ranges with units, trends, notable values, data gaps. No diagnosis."]],
                 ["title", "start", "end", "labels", "summary"]),
        ]
    }

    // MARK: Execution

    struct ToolError: Error, CustomStringConvertible { let description: String }

    /// Runs one tool; returns a compact JSON string (truncated with a note when too long).
    func run(_ name: String, _ input: [String: Any]) throws -> String {
        let result: Any
        switch name {
        case "list_available_data": result = try listAvailable()
        case "get_inferences": result = try inferences(kind: str(input, "kind"), range: try range(input))
        case "get_daily_summary": result = try dailySummary(try day(str(input, "date")))
        case "get_series": result = try series(label: str(input, "label"), range: try range(input),
                                               bucket: str(input, "bucket"), agg: str(input, "agg"))
        case "get_sleep_nights": result = try sleepNights(try range(input))
        case "get_visits": result = try visits(try range(input))
        case "get_screen_events": result = try screenEvents(try range(input))
        case "list_report_labels": result = try reportLabels(try range(input))
        default: throw ToolError(description: "unknown tool \(name)")
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
        var s = String(data: data, encoding: .utf8) ?? "{}"
        if s.count > Self.maxResultChars {
            s = String(s.prefix(Self.maxResultChars)) + "…[truncated: narrow the date range or use a larger bucket]"
        }
        return s
    }

    private func str(_ input: [String: Any], _ k: String) throws -> String {
        guard let v = input[k] as? String, !v.isEmpty else { throw ToolError(description: "missing \(k)") }
        return v
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// Local day [start, end) as unix seconds.
    private func day(_ s: String) throws -> (Double, Double) {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: String(s.prefix(10))) else { throw ToolError(description: "bad date \(s), use YYYY-MM-DD") }
        let start = calendar.startOfDay(for: d)
        return (start.timeIntervalSince1970, calendar.date(byAdding: .day, value: 1, to: start)!.timeIntervalSince1970)
    }

    private func range(_ input: [String: Any]) throws -> (Double, Double) {
        let a = try day(str(input, "start")).0, b = try day(str(input, "end")).1
        guard b > a else { throw ToolError(description: "end is before start") }
        guard b - a <= 400 * 86400 else { throw ToolError(description: "range too long (max 400 days)") }
        return (a, b)
    }

    private func iso(_ ts: Double?) -> Any {
        guard let ts else { return NSNull() }
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    // MARK: Tools

    private func listAvailable() throws -> Any {
        let labels = try query.rows("""
            SELECT label, COUNT(*) AS n, MIN(start_ts) AS lo, MAX(end_ts) AS hi FROM processed_samples
            WHERE deleted = 0 GROUP BY label ORDER BY n DESC
            """).map { ["label": $0["label"] as String, "rows": $0["n"] as Int, "first": iso($0["lo"]), "last": iso($0["hi"])] }
        let kinds = try query.rows("""
            SELECT kind, COUNT(*) AS n, MIN(minute_start) AS lo, MAX(minute_end) AS hi FROM inferences
            WHERE superseded_by IS NULL GROUP BY kind
            """).map { ["kind": $0["kind"] as String, "rows": $0["n"] as Int,
                        "first": iso(Double($0["lo"] as Int64) * 60), "last": iso(Double($0["hi"] as Int64) * 60)] }
        let places = try query.rows("SELECT name, kind FROM context_places WHERE kind != 'suggested'")
            .map { ["name": $0["name"] as String, "kind": $0["kind"] as String] }
        return ["labels": Array(labels.prefix(Self.maxRows)), "inference_kinds": kinds, "places": places,
                "time_zone": timeZone.identifier]
    }

    private func inferences(kind: String, range: (Double, Double)) throws -> Any {
        let rows = try query.rows("""
            SELECT value_json, confidence, provisional FROM inferences
            WHERE kind = ? AND superseded_by IS NULL AND minute_end > ? AND minute_start < ? ORDER BY minute_start LIMIT ?
            """, [kind, Int64(range.0 / 60), Int64(range.1 / 60), Self.maxRows])
        return ["kind": kind, "rows": rows.map { r -> Any in
            var v = (try? JSONSerialization.jsonObject(with: Data((r["value_json"] as String).utf8))) as? [String: Any] ?? [:]
            v["confidence"] = (r["confidence"] as Double?) ?? NSNull()
            if (r["provisional"] as Int) == 1 { v["provisional"] = true }
            return v
        }, "truncated": rows.count == Self.maxRows]
    }

    private func dailySummary(_ d: (Double, Double)) throws -> Any {
        let date = String((iso(d.0) as? String ?? "").prefix(10))
        let nights = (try? sleepNights((d.0, d.1))) as? [String: Any]
        let act = try inferences(kind: "activity_day", range: d) as? [String: Any]
        let plan = try query.rows("""
            SELECT value_json FROM inferences WHERE kind = 'wind_down_plan' AND superseded_by IS NULL
            AND json_extract(value_json, '$.night_of') = ? ORDER BY id DESC LIMIT 1
            """, [date]).first.map { $0["value_json"] as String }
        let outcome = try query.rows("""
            SELECT value_json FROM inferences WHERE kind = 'wind_down_outcome'
            AND json_extract(value_json, '$.night_of') = ? LIMIT 1
            """, [date]).first.map { $0["value_json"] as String }
        let obj: (String?) -> Any = { s in s.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? NSNull() }
        return ["date": date, "last_night_sleep": (nights?["nights"] as? [Any])?.first ?? NSNull(),
                "activity": (act?["rows"] as? [Any])?.first ?? NSNull(),
                "visits": (try visits(d) as? [String: Any])?["visits"] ?? [],
                "screen_events": (try screenEvents(d) as? [String: Any])?["events"] ?? [],
                "wind_down_plan": obj(plan), "wind_down_outcome": obj(outcome)]
    }

    private func series(label: String, range: (Double, Double), bucket: String, agg: String) throws -> Any {
        let size: Double = ["5m": 300, "15m": 900, "1h": 3600, "1d": 86400][bucket] ?? 3600
        guard ["avg", "sum", "min", "max"].contains(agg) else { throw ToolError(description: "bad agg") }
        guard (range.1 - range.0) / size <= Double(Self.maxBuckets) else {
            throw ToolError(description: "too many buckets (max \(Self.maxBuckets)); use a larger bucket or shorter range")
        }
        // Daily buckets follow local midnight; shorter ones are aligned in UTC (same in any zone for ≤ 1 h).
        let offset = Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: range.0)))
        let rows = try query.rows("""
            SELECT CAST((start_ts + ?) / ? AS INTEGER) AS b, \(agg.uppercased())(value) AS v, COUNT(*) AS n, MAX(unit) AS unit
            FROM processed_samples WHERE label = ? AND deleted = 0 AND value IS NOT NULL AND start_ts >= ? AND start_ts < ?
            GROUP BY b ORDER BY b
            """, [bucket == "1d" ? offset : 0, size, label, range.0, range.1])
        return ["label": label, "bucket": bucket, "agg": agg, "unit": rows.first.map { ($0["unit"] as String?) ?? "" } ?? "",
                "points": rows.map { r -> [Any] in
                    let start = Double(r["b"] as Int64) * size - (bucket == "1d" ? offset : 0)
                    return [iso(start), ((r["v"] as Double?) ?? 0).rounded(toPlaces: 2), r["n"] as Int]
                }]
    }

    private func sleepNights(_ range: (Double, Double)) throws -> Any {
        let r = try python.call("sleep_nights", ["db_path": dbPath, "tz": timeZone.identifier,
                                                 "start_ts": range.0, "end_ts": range.1]) as? [String: Any] ?? [:]
        let nights = (r["nights"] as? [[String: Any]] ?? []).prefix(Self.maxRows).map { n -> [String: Any] in
            ["night_of": n["night_of"] ?? NSNull(), "onset": iso(n["onset_ts"] as? Double), "wake": iso(n["wake_ts"] as? Double),
             "in_bed": iso(n["in_bed_ts"] as? Double), "asleep_min": n["asleep_min"] ?? NSNull(),
             "latency_min": n["latency_min"] ?? NSNull(), "stage_min": n["stage_min"] ?? [:]]
        }
        return ["nights": Array(nights)]
    }

    private func visits(_ range: (Double, Double)) throws -> Any {
        let rows = try query.rows("""
            SELECT v.arrival_ts AS a, v.departure_ts AS d, p.name AS name, p.kind AS kind FROM context_visits v
            LEFT JOIN context_places p ON p.id = v.place_id
            WHERE v.arrival_ts < ? AND (v.departure_ts IS NULL OR v.departure_ts > ?) ORDER BY v.arrival_ts LIMIT ?
            """, [range.1, range.0, Self.maxRows])
        // No coordinates: place names are enough for patterns and keep location private.
        return ["visits": rows.map { r -> [String: Any] in
            let a: Double = r["a"], d: Double? = r["d"]
            return ["place": (r["name"] as String?) ?? "unnamed place", "kind": (r["kind"] as String?) ?? "unnamed",
                    "arrival": iso(a), "departure": iso(d), "minutes": d.map { Int(($0 - a) / 60) } ?? NSNull()]
        }]
    }

    private func reportLabels(_ range: (Double, Double)) throws -> Any {
        let rows = try query.queue.read { db in try ReportData.available(db, range: range) }
        var groups: [String: [[String: Any]]] = [:]
        for a in rows {
            groups[a.group, default: []].append(["label": a.label, "name": a.title, "rows": a.rows, "unit": a.unit ?? "",
                                                 "first": iso(a.first), "last": iso(a.last)])
        }
        return ["groups": groups, "note": "Use these label values in create_report."]
    }

    private func screenEvents(_ range: (Double, Double)) throws -> Any {
        let rows = try query.rows("""
            SELECT ts, schedule, threshold_min FROM context_screen_events WHERE ts >= ? AND ts < ? ORDER BY ts LIMIT ?
            """, [range.0, range.1, Self.maxRows])
        return ["events": rows.map { ["ts": iso($0["ts"]), "schedule": $0["schedule"] as String,
                                      "threshold_min": $0["threshold_min"] as Int] },
                "note": rows.isEmpty ? "Screen Time is not enabled on this account (needs the paid developer account)." : ""]
    }
}

/// Read-only access for Claude tools: the DB is opened read-only and any SQL naming a raw
/// table is refused before it runs (spec §13: no tool can read raw watch data).
struct ReadOnlyQuery: Sendable {
    let queue: DatabaseQueue

    init(path: String) throws {
        var c = Configuration()
        c.readonly = true
        queue = try DatabaseQueue(path: path, configuration: c)
    }

    static func allowed(_ sql: String) -> Bool {
        let s = sql.lowercased()
        return !ClaudeTools.rawTables.contains { s.contains($0) } && !s.contains("payload")
    }

    func rows(_ sql: String, _ args: [any DatabaseValueConvertible] = []) throws -> [Row] {
        guard Self.allowed(sql) else { throw ClaudeTools.ToolError(description: "query touches raw watch data") }
        return try queue.read { db in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)) }
    }
}

extension Double {
    func rounded(toPlaces p: Int) -> Double {
        let m = pow(10.0, Double(p))
        return (self * m).rounded() / m
    }
}
