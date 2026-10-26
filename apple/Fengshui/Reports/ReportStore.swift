import FengshuiKit
import Foundation
import GRDB

struct ReportRecord: Sendable, Equatable, Identifiable {
    var id: Int64
    var createdAt: Double
    var kind: String
    var title: String
    var purpose: String?
    var startDate: String
    var endDate: String
    var labels: [String]
    var summary: String?
    var question: String?
    var fileName: String
    var pages: Int
    var bytes: Int
}

/// Filters for the saved-reports list: labels and a date or date range (DECISIONS D-20).
struct ReportFilter: Sendable, Equatable {
    enum DateMode: String, CaseIterable, Sendable { case any = "Any date", day = "Day", range = "Range" }
    enum Kind: String, CaseIterable, Sendable { case all = "All", report = "Reports", question = "Questions" }
    var dateMode: DateMode = .any
    /// YYYY-MM-DD; `end` is ignored in day mode.
    var start = ""
    var end = ""
    var labels: Set<String> = []
    var kind: Kind = .all
    var text = ""

    var isActive: Bool { dateMode != .any || !labels.isEmpty || kind != .all || !text.isEmpty }

    func matches(_ r: ReportRecord) -> Bool {
        if kind == .report && r.kind != "report" { return false }
        if kind == .question && r.kind != "question" { return false }
        if !labels.isEmpty && labels.isDisjoint(with: r.labels) { return false }
        if !text.isEmpty, ![r.title, r.purpose ?? "", r.question ?? ""].contains(where: { $0.localizedCaseInsensitiveContains(text) }) {
            return false
        }
        switch dateMode {
        case .any: return true
        // Dates are YYYY-MM-DD, so string order is date order: keep reports whose period overlaps.
        case .day: return r.startDate <= start && r.endDate >= start
        case .range: return r.startDate <= end && r.endDate >= start
        }
    }
}

final class ReportStore: Sendable {
    let directory: URL
    private let db: AppDatabase
    private let clock: Clock
    private let timeZone: TimeZone
    private let inbox: InboxStore

    init(db: AppDatabase, clock: Clock, timeZone: TimeZone, inbox: InboxStore, directory: URL = ReportStore.defaultDirectory()) {
        self.db = db
        self.clock = clock
        self.timeZone = timeZone
        self.inbox = inbox
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("reports")
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    func url(_ r: ReportRecord) -> URL { directory.appendingPathComponent(r.fileName) }

    func create(_ req: ReportRequest) async throws -> ReportRecord {
        guard let range = ReportData.range(start: req.startDate, end: req.endDate, timeZone: timeZone) else {
            throw Failure(description: "invalid period \(req.startDate) – \(req.endDate)")
        }
        guard range.1 - range.0 <= 400 * 86_400 else { throw Failure(description: "period too long (max 400 days)") }
        let tz = timeZone
        let sections = try await db.writer.read { db in
            try ReportData.sections(db, labels: req.labels, range: range, timeZone: tz)
        }
        let now = clock.now
        let out = ReportPDF.render(req, sections: sections, generatedAt: now, timeZone: tz)
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let slug = req.title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(40)
        let name = "fengshui-\(String(slug))-\(stamp)-\(UUID().uuidString.prefix(4)).pdf"
        try out.data.write(to: directory.appendingPathComponent(name), options: .atomic)
        let labelsJSON = String(data: try JSONEncoder().encode(req.labels), encoding: .utf8)!
        let id = try await db.writer.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO reports (created_at, kind, title, purpose, start_date, end_date, labels_json, summary, question,
                                     ai_log_id, file_name, pages, bytes) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, arguments: [now.timeIntervalSince1970, req.kind.rawValue, req.title, req.purpose, req.startDate,
                                 req.endDate, labelsJSON, req.summary, req.question, req.aiLogID, name, out.pages,
                                 out.data.count])
            return db.lastInsertedRowID
        }
        inbox.add(identifier: "report-\(id)", kind: "report", title: "Report ready: \(req.title)",
                  body: "\(out.pages) page\(out.pages == 1 ? "" : "s") · \(Fmt.period(req.startDate, req.endDate, tz)) · "
                      + "\(req.labels.count) data type\(req.labels.count == 1 ? "" : "s")", link: "report:\(id)")
        await inbox.updateBadge()
        guard let rec = record(id) else { throw Failure(description: "report not saved") }
        return rec
    }

    static func fetchAll(_ db: Database) throws -> [ReportRecord] {
        try Row.fetchAll(db, sql: "SELECT * FROM reports ORDER BY created_at DESC, id DESC").map(Self.record)
    }

    private static func record(_ r: Row) -> ReportRecord {
        let labels = (try? JSONDecoder().decode([String].self, from: Data((r["labels_json"] as String).utf8))) ?? []
        return ReportRecord(id: r["id"], createdAt: r["created_at"], kind: r["kind"], title: r["title"], purpose: r["purpose"],
                            startDate: r["start_date"], endDate: r["end_date"], labels: labels, summary: r["summary"],
                            question: r["question"], fileName: r["file_name"], pages: r["pages"], bytes: r["bytes"])
    }

    func all() -> [ReportRecord] { (try? db.writer.read { try Self.fetchAll($0) }) ?? [] }

    func record(_ id: Int64) -> ReportRecord? {
        try? db.writer.read { db in try Row.fetchOne(db, sql: "SELECT * FROM reports WHERE id = ?", arguments: [id]).map(Self.record) }
    }

    func delete(_ ids: [Int64]) async {
        for id in ids {
            if let r = record(id) { try? FileManager.default.removeItem(at: url(r)) }
        }
        try? await db.writer.write { db in
            try db.execute(sql: "DELETE FROM reports WHERE id IN (\(ids.map(String.init).joined(separator: ",")))")
        }
    }

    func available(start: String, end: String) -> [ReportData.Available] {
        guard let range = ReportData.range(start: start, end: end, timeZone: timeZone) else { return [] }
        return (try? db.writer.read { try ReportData.available($0, range: range) }) ?? []
    }

    // MARK: Every question gets a report

    /// Period and labels the answer looked at, from its tool calls; the last 7 days if none.
    func scope(of answer: ClaudeAssistant.Answer) -> (start: String, end: String, labels: [String]) {
        var starts: [String] = [], ends: [String] = [], labels: [String] = []
        for c in answer.calls {
            if let s = c.input["start"] { starts.append(String(s.prefix(10))) }
            if let e = c.input["end"] { ends.append(String(e.prefix(10))) }
            if let d = c.input["date"] { starts.append(String(d.prefix(10))); ends.append(String(d.prefix(10))) }
            switch c.name {
            case "get_series": if let l = c.input["label"] { labels.append(l) }
            case "get_sleep_nights": labels.append("sleep_analysis")
            case "get_daily_summary": labels += ["sleep_analysis", "step_count", "active_energy_burned"]
            case "get_inferences":
                labels += (c.input["kind"] ?? "").hasPrefix("wind_down") ? ["sleep_analysis"] : ["step_count", "heart_rate"]
            default: break
            }
        }
        let today = ReportData.dayString(clock.now, timeZone)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let weekAgo = ReportData.dayString(cal.date(byAdding: .day, value: -6, to: clock.now)!, timeZone)
        let start = starts.min() ?? weekAgo, end = Swift.min(ends.max() ?? today, today)
        var seen = Set<String>()
        return (start, Swift.max(start, end), labels.filter { seen.insert($0).inserted })
    }

    /// The Ask tab calls this after each answer (unless the answer already created a report).
    func questionReport(question: String, answer: ClaudeAssistant.Answer) async -> ReportRecord? {
        guard answer.reportIDs.isEmpty, answer.error == nil || answer.error == "tool_round_limit" else { return nil }
        let sc = scope(of: answer)
        let present = Set(available(start: sc.start, end: sc.end).map(\.label))
        let title = question.count > 60 ? String(question.prefix(57)) + "…" : question
        let req = ReportRequest(kind: .question, title: title, purpose: nil, startDate: sc.start, endDate: sc.end,
                                labels: sc.labels.filter(present.contains), summary: answer.text, question: question,
                                aiLogID: answer.logID)
        return try? await create(req)
    }
}
