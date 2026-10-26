import FengshuiKit
import GRDB
import PDFKit
import XCTest
@testable import Fengshui

final class InboxTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_519_200)

    func make(_ name: String) throws -> (InboxStore, FakeNotificationCenter) {
        let center = FakeNotificationCenter()
        return (InboxStore(db: try AppDatabase.temporary(name), clock: FixedClock(now), center: center), center)
    }

    func testDeliveredNotificationsAreFiledOnceAndBadgeCountsUnread() async throws {
        let (inbox, center) = try make("inbox-ingest")
        try await center.add(LocalNotification(identifier: "wind_down_2026-10-20", title: "Start winding down", body: "Lights low",
                                               fireDate: now), timeZone: .current)
        try await center.add(LocalNotification(identifier: "monitor-7", title: "Unusual reading", body: "HR high",
                                               fireDate: nil, userInfo: ["kind": "monitor"]), timeZone: .current)
        center.deliver("wind_down_2026-10-20", at: now)
        center.deliver("monitor-7", at: now.addingTimeInterval(60))
        await inbox.ingestDelivered()
        await inbox.ingestDelivered()                      // idempotent
        let all = inbox.all()
        XCTAssertEqual(all.map(\.identifier), ["monitor-7", "wind_down_2026-10-20"])
        XCTAssertEqual(all.map(\.kind), ["monitor", "wind_down"])
        XCTAssertEqual(center.badge, 2)
        await inbox.markRead([all[0].id])
        XCTAssertEqual(inbox.unreadCount(), 1)
        XCTAssertEqual(center.badge, 1)
    }

    func testDeleteSelectedAndDeleteAfterReading() async throws {
        let (inbox, _) = try make("inbox-delete")
        for i in 0..<4 { inbox.add(identifier: "m\(i)", kind: "other", title: "T\(i)", body: "B") }
        let ids = inbox.all().map(\.id)
        await inbox.delete(Array(ids.prefix(2)))
        XCTAssertEqual(inbox.all().count, 2)
        inbox.setDeleteAfterRead(true)
        await inbox.markRead([inbox.all()[0].id])
        XCTAssertEqual(inbox.all().count, 1, "read message is deleted when delete-after-reading is on")
        inbox.setDeleteAfterRead(false)
        await inbox.markAllRead()
        XCTAssertEqual(inbox.all().count, 1)
        await inbox.deleteRead()
        XCTAssertEqual(inbox.all().count, 0)
    }
}

final class ReportTests: XCTestCase {
    func env(_ name: String) throws -> (AppDatabase, ReportStore, InboxStore, Scenario) {
        let src = repoRoot.appendingPathComponent("build/parity/mac.sqlite")
        guard FileManager.default.fileExists(atPath: src.path) else { throw XCTSkip("run engine/tests/parity.py first") }
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("report-\(UUID()).sqlite")
        try FileManager.default.copyItem(at: src, to: dst)
        let db = try AppDatabase(path: dst.path)
        let sc = try Scenario.load("typical_week", bundle: Bundle(for: Self.self))
        let clock = FixedClock(Date(timeIntervalSince1970: sc.now))
        let inbox = InboxStore(db: db, clock: clock, center: FakeNotificationCenter())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reports-\(name)-\(UUID())")
        return (db, ReportStore(db: db, clock: clock, timeZone: TimeZone(identifier: sc.tz)!, inbox: inbox, directory: dir), inbox, sc)
    }

    func days(_ sc: Scenario, back: Int) -> (String, String) {
        let tz = TimeZone(identifier: sc.tz)!
        let now = Date(timeIntervalSince1970: sc.now)
        return (ReportData.dayString(now.addingTimeInterval(-Double(back) * 86_400), tz), ReportData.dayString(now, tz))
    }

    func testAvailableLabelsAreGroupedAndLimitedToThePeriod() throws {
        let (_, store, _, sc) = try env("avail")
        let (a, b) = days(sc, back: 6)
        let avail = store.available(start: a, end: b)
        let labels = Set(avail.map(\.label))
        XCTAssertTrue(labels.isSuperset(of: ["heart_rate", "step_count", "sleep_analysis"]), "\(labels)")
        XCTAssertEqual(avail.first { $0.label == "heart_rate" }?.group, "Vitals")
        XCTAssertEqual(avail.first { $0.label == "sleep_analysis" }?.group, "Sleep")
        // A period before any data has nothing.
        XCTAssertTrue(store.available(start: "2001-01-01", end: "2001-01-02").isEmpty)
    }

    func testCreateWritesAPDFWithEverySectionAndAnInboxMessage() async throws {
        let (_, store, inbox, sc) = try env("pdf")
        let (a, b) = days(sc, back: 6)
        let req = ReportRequest(title: "Sleep review for my GP", purpose: "sleep", startDate: a, endDate: b,
                                labels: ["sleep_analysis", "heart_rate", "step_count", "resting_heart_rate", "no_such_label"],
                                summary: "**Sleep** averaged 7 h.\n- Resting HR stable")
        let r = try await store.create(req)
        let doc = try XCTUnwrap(PDFDocument(url: store.url(r)))
        XCTAssertEqual(doc.pageCount, r.pages)
        XCTAssertGreaterThanOrEqual(r.pages, 2)
        let text = doc.string ?? ""
        for s in ["Sleep review for my GP", "Summary", "Sleep averaged 7 h.", "• Resting HR stable", "Heart rate (bpm)",
                  "Steps (steps)", "Night (wake date)", "No data in this period: No Such Label", "page 1 of \(r.pages)",
                  "Not a medical device"] {
            XCTAssertTrue(text.contains(s), "PDF is missing “\(s)”")
        }
        XCTAssertFalse(text.contains("**"))
        let msg = try XCTUnwrap(inbox.all().first)
        XCTAssertEqual(msg.kind, "report")
        XCTAssertEqual(msg.link, "report:\(r.id)")
        await store.delete([r.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(r).path))
        XCTAssertNil(store.record(r.id))
    }

    func testSectionStatsUseEverydayUnitsAndPerSourceTotals() throws {
        let db = try AppDatabase.temporary("report-units")
        let tz = TimeZone(identifier: "America/New_York")!
        try db.writer.write { d in
            let day = 1_792_468_800.0            // 2026-10-20 00:00 New York
            for (i, (v, src)) in [(1.0, "Watch"), (1.5, "Watch"), (90.0, "Phone")].enumerated() {
                try d.execute(sql: """
                    INSERT INTO processed_samples (hk_uuid, hk_type, label, value, unit, start_ts, end_ts, minute_id, source_name, inserted_at)
                    VALUES (?, 'T', 'heart_rate', ?, ?, ?, ?, 0, ?, 0)
                    """, arguments: ["h\(i)", v, src == "Phone" ? "count/min" : "count/s", day + 3_600 * Double(i + 1),
                                     day + 3_600 * Double(i + 1), src])
            }
            for (i, (v, src)) in [(3_000.0, "Watch"), (1_000.0, "Watch"), (3_500.0, "Phone")].enumerated() {
                try d.execute(sql: """
                    INSERT INTO processed_samples (hk_uuid, hk_type, label, value, unit, start_ts, end_ts, minute_id, source_name, inserted_at)
                    VALUES (?, 'T', 'step_count', ?, 'count', ?, ?, 0, ?, 0)
                    """, arguments: ["s\(i)", v, day + 3_600 * Double(i + 1), day + 3_600 * Double(i + 1), src])
            }
        }
        let range = try XCTUnwrap(ReportData.range(start: "2026-10-20", end: "2026-10-20", timeZone: tz))
        let s = try db.writer.read { try ReportData.sections($0, labels: ["step_count", "heart_rate"], range: range, timeZone: tz) }
        XCTAssertEqual(s.map(\.label), ["heart_rate", "step_count"], "vitals before activity")
        XCTAssertEqual(s[0].unit, "bpm")
        XCTAssertEqual(s[0].mean ?? 0, 80, accuracy: 0.01)           // (60 + 90 + 90) / 3
        XCTAssertEqual(s[0].min, 60)
        XCTAssertEqual(s[1].kind, .cumulative)
        XCTAssertEqual(s[1].total, 4_000)                           // per-source max, not 7 500
    }

    func testFilterByLabelsDayAndRange() {
        let r = ReportRecord(id: 1, createdAt: 0, kind: "report", title: "GP sleep", purpose: nil, startDate: "2026-10-01",
                             endDate: "2026-10-07", labels: ["sleep_analysis", "heart_rate"], summary: nil, question: nil,
                             fileName: "x.pdf", pages: 2, bytes: 1)
        var f = ReportFilter()
        XCTAssertTrue(f.matches(r))
        f.labels = ["step_count"]
        XCTAssertFalse(f.matches(r))
        f.labels = ["step_count", "heart_rate"]
        XCTAssertTrue(f.matches(r))
        f.dateMode = .day; f.start = "2026-10-08"
        XCTAssertFalse(f.matches(r))
        f.start = "2026-10-07"
        XCTAssertTrue(f.matches(r))
        f.dateMode = .range; f.start = "2026-09-20"; f.end = "2026-10-01"
        XCTAssertTrue(f.matches(r), "overlaps on the first day")
        f.end = "2026-09-30"
        XCTAssertFalse(f.matches(r))
        f = ReportFilter(); f.kind = .question
        XCTAssertFalse(f.matches(r))
        f = ReportFilter(); f.text = "sleep"
        XCTAssertTrue(f.matches(r))
    }

    /// The Report tab's two AI steps: suggest labels, then write the summary and create the PDF
    /// with the user's filter enforced.
    func testAISuggestsLabelsThenCreatesReportWithTheUsersFilter() async throws {
        let (db, store, _, sc) = try env("ai")
        let (a, b) = days(sc, back: 6)
        let tz = TimeZone(identifier: sc.tz)!
        let tools = try ClaudeTools(dbPath: db.path, timeZone: tz)
        let t = MockTransport()
        t.script = [
            { _, _ in MockTransport.toolUse([("list_report_labels", ["start": a, "end": b])]) },
            { _, body in
                // The tool result listed the labels by group.
                let msgs = body["messages"] as! [[String: Any]]
                let result = ((msgs.last!["content"] as! [[String: Any]]).first!["content"] as! String)
                XCTAssertTrue(result.contains("\"Vitals\"") && result.contains("heart_rate"))
                return MockTransport.toolUse([("propose_report_labels", ["labels": ["heart_rate", "sleep_analysis"],
                                                                         "reasons": ["Resting trend, overnight", "Duration, stages"]])])
            },
            { _, _ in MockTransport.final("Chose 2 labels.") },
        ]
        let assistant = ClaudeAssistant(db: db, tools: tools, transport: t, clock: FixedClock(Date(timeIntervalSince1970: sc.now)),
                                        timeZone: tz, model: ClaudeAssistant.smokeTestModel, actions: ReportActions(store: store))
        let s = await assistant.ask(ReportPrompts.suggest(start: a, end: b, purpose: "sleep"))
        XCTAssertEqual(s.proposedLabels, ["heart_rate", "sleep_analysis"])
        XCTAssertEqual(s.calls.last?.input["reasons"], "Resting trend, overnight\nDuration, stages")

        // The user adds steps; the model tries other dates and labels, but the filter wins.
        let forced = ReportRequest(title: "For Dr. Lee", purpose: "sleep", startDate: a, endDate: b,
                                   labels: ["heart_rate", "sleep_analysis", "step_count"])
        let t2 = MockTransport()
        t2.script = [
            { _, _ in MockTransport.toolUse([("create_report", ["title": "x", "start": "2020-01-01", "end": "2020-01-02",
                                                                "labels": ["heart_rate"], "summary": "Slept 7 h on average."])]) },
            { _, _ in MockTransport.final("Done.") },
        ]
        let a2 = ClaudeAssistant(db: db, tools: tools, transport: t2, clock: FixedClock(Date(timeIntervalSince1970: sc.now)),
                                 timeZone: tz, model: ClaudeAssistant.smokeTestModel, actions: ReportActions(store: store, forced: forced))
        let c = await a2.ask(ReportPrompts.create(forced))
        let r = try XCTUnwrap(c.reportIDs.last.flatMap(store.record))
        XCTAssertEqual(r.title, "For Dr. Lee")
        XCTAssertEqual([r.startDate, r.endDate], [a, b])
        XCTAssertEqual(r.labels, ["heart_rate", "sleep_analysis", "step_count"])
        XCTAssertEqual(r.summary, "Slept 7 h on average.")
        XCTAssertEqual(r.answeredBy, "Claude API · \(ClaudeAssistant.smokeTestModel)")
        // A question answer that already created a report doesn't get a second one.
        let none = await store.questionReport(question: "q", answer: c)
        XCTAssertNil(none)
    }

    func testEveryQuestionGetsAReportScopedToTheToolCalls() async throws {
        let (_, store, _, sc) = try env("question")
        let (a, b) = days(sc, back: 2)
        var ans = ClaudeAssistant.Answer(text: "You slept about 7 hours and walked 9,000 steps a day.",
                                         answeredBy: "Managed Agent “FengShui Agent” (agent_x) · session sesn_y")
        ans.calls = [.init(name: "get_sleep_nights", input: ["start": a, "end": b]),
                     .init(name: "get_series", input: ["label": "step_count", "start": a, "end": b, "bucket": "1d", "agg": "sum"]),
                     .init(name: "get_series", input: ["label": "step_count", "start": a, "end": b, "bucket": "1h", "agg": "sum"])]
        let r = try await XCTUnwrapAsync(await store.questionReport(question: "How did I sleep and move lately?", answer: ans))
        XCTAssertEqual(r.kind, "question")
        XCTAssertEqual([r.startDate, r.endDate], [a, b])
        XCTAssertEqual(r.labels, ["sleep_analysis", "step_count"])
        XCTAssertEqual(r.question, "How did I sleep and move lately?")
        let text = PDFDocument(url: store.url(r))?.string ?? ""
        XCTAssertTrue(text.contains("Question") && text.contains("Answer") && text.contains("walked 9,000 steps"))
        XCTAssertEqual(r.answeredBy, "Managed Agent “FengShui Agent” (agent_x) · session sesn_y")
        XCTAssertTrue(text.contains("Answered by: Managed Agent"))
        // No tools called: the last 7 days, question and answer only.
        let plain = try await XCTUnwrapAsync(await store.questionReport(question: "Hi?", answer: .init(text: "Hello.")))
        XCTAssertEqual(plain.labels, [])
        XCTAssertEqual(plain.endDate, ReportData.dayString(Date(timeIntervalSince1970: sc.now), TimeZone(identifier: sc.tz)!))
        // Failed answers (no key, network) don't make reports.
        let failed = await store.questionReport(question: "x", answer: .init(text: "Couldn't reach Claude", error: "network"))
        XCTAssertNil(failed)
    }

    func testReportToolsAreReadOnlyAndNeverExposeRawData() throws {
        let (db, _, _, sc) = try env("tools")
        let (a, b) = days(sc, back: 6)
        let out = try ClaudeTools(dbPath: db.path, timeZone: TimeZone(identifier: sc.tz)!).run("list_report_labels", ["start": a, "end": b])
        for m in ClaudeTests.rawMarkers { XCTAssertFalse(out.contains(m), m) }
        XCTAssertThrowsError(try ClaudeTools(dbPath: db.path, timeZone: .current).run("create_report", [:]),
                             "create_report runs only through the app's actions")
    }
}

func XCTUnwrapAsync<T>(_ v: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(v, file: file, line: line)
}

final class MonitorClientTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_519_200)

    override func setUp() {
        StubServer.requests = []
    }

    func make(_ name: String) throws -> (AppDatabase, MonitorClient, InboxStore, FakeNotificationCenter) {
        let db = try AppDatabase.temporary(name)
        try db.setPreference(ServerSync.urlKey, "http://stub.local:8765")
        let clock = FixedClock(now)
        let log = EventLog()
        let server = ServerSync(db: db, secrets: MemorySecretStore([SecretKey.serverToken: "t"]), network: FixedNetworkStatus(onWiFi: true),
                                clock: clock, log: log, session: StubServer.session(), deviceID: "d")
        let center = FakeNotificationCenter()
        let inbox = InboxStore(db: db, clock: clock, center: center)
        return (db, MonitorClient(db: db, server: server, clock: clock, inbox: inbox, notifications: center, log: log,
                                  deviceID: "d", liveSync: {}), inbox, center)
    }

    static func session(_ id: Int, start: Double, interval: Double = 300) -> [String: Any] {
        ["id": id, "status": "active", "start_ts": start, "end_ts": start + 7_200, "interval_s": interval, "mode": "pull",
         "next_due_ts": start + interval,
         "stats": ["intervals": 1, "intervals_with_data": 1, "coverage": 1.0, "readings": 1, "requests_sent": 0, "alerts": 0]]
    }

    func testStartSendsProcessedReadingsAndFilesAlerts() async throws {
        let (db, monitor, inbox, center) = try make("monitor")
        let t = now.timeIntervalSince1970
        try await db.writer.write { d in
            for (i, (label, v, unit)) in [("heart_rate", 2.0, "count/s"), ("oxygen_saturation", 0.95, "%"),
                                          ("resting_heart_rate", 58.0, "count/min"), ("body_mass", 70.0, "kg")].enumerated() {
                try d.execute(sql: """
                    INSERT INTO processed_samples (hk_uuid, hk_type, label, value, unit, start_ts, end_ts, minute_id, inserted_at)
                    VALUES (?, 'T', ?, ?, ?, ?, ?, 0, 0)
                    """, arguments: ["m\(i)", label, v, unit, t - 600, t - 600])
            }
            try d.execute(sql: """
                INSERT INTO raw_chunks (minute_id, sensor, tier, rate_hz, sample_count, axes, encoding, scale, payload, received_at)
                VALUES (1, 'hr_session', 3, 0.2, 1, 1, 'fsr1-i16-delta-deflate', 1, x'00', 0)
                """)
        }
        StubServer.handler = { path, body in
            if path.hasSuffix("/monitor/sessions") { return (200, Self.session(4, start: t)) }
            if path.hasSuffix("/monitor/readings") {
                return (200, ["session": Self.session(4, start: t),
                              "alerts": [["id": 11, "ts": t, "severity": "warning", "title": "High heart rate at rest",
                                          "body": "120 bpm for 10 min", "pushed": 0]]])
            }
            return (404, [:])
        }
        let s = try await monitor.start(intervalMin: 5, durationH: 2)
        XCTAssertEqual(s.id, 4)
        let startBody = StubServer.requests.first { $0.path.hasSuffix("/monitor/sessions") }!.body
        XCTAssertEqual(startBody["interval_min"] as? Double, 5)
        XCTAssertEqual(startBody["duration_h"] as? Double, 2)
        XCTAssertNil(startBody["push_token"], "no token on a free account")
        let readings = StubServer.requests.first { $0.path.hasSuffix("/monitor/readings") }!.body
        let samples = readings["samples"] as! [[String: Any]]
        XCTAssertEqual(Set(samples.map { $0["label"] as! String }), ["heart_rate", "oxygen_saturation", "resting_heart_rate"])
        XCTAssertEqual(samples.first { $0["label"] as? String == "heart_rate" }?["value"] as? Double, 120)
        XCTAssertEqual(samples.first { $0["label"] as? String == "oxygen_saturation" }?["value"] as? Double ?? 0, 95, accuracy: 0.001)
        XCTAssertEqual((readings["baselines"] as? [String: Double])?["resting_heart_rate"], 58)
        let json = String(data: try JSONSerialization.data(withJSONObject: readings), encoding: .utf8)!
        for m in ["hr_session", "payload", "raw_chunks", "fsr1"] { XCTAssertFalse(json.contains(m), "raw data leaked: \(m)") }
        // The alert is in the inbox and was shown as a notification (the server didn't push it).
        XCTAssertEqual(inbox.all().map(\.identifier), ["monitor-11"])
        XCTAssertEqual(center.added.last?.identifier, "monitor-11")
        // Pulling the same alert again files nothing new.
        StubServer.handler = { path, _ in
            path.hasSuffix("/monitor/alerts") ? (200, ["alerts": [["id": 11, "ts": t, "title": "x", "body": "y", "pushed": 0]]]) : (404, [:])
        }
        await monitor.pullAlerts()
        XCTAssertEqual(inbox.all().count, 1)
        XCTAssertEqual(center.added.count, 1)
        XCTAssertEqual(StubServer.requests.last?.path, "/monitor/alerts")
    }

    func testDueOnlyAfterAnInterval() async throws {
        let (db, monitor, _, _) = try make("monitor-due")
        let t = now.timeIntervalSince1970
        let s = try XCTUnwrap(MonitorSession.from(Self.session(1, start: t - 1_000)))
        try db.setPreference(MonitorClient.lastSentKey, t - 100)
        XCTAssertFalse(monitor.isDue(s, now: now))
        try db.setPreference(MonitorClient.lastSentKey, t - 290)
        XCTAssertTrue(monitor.isDue(s, now: now), "15 s tolerance")
        var ended = s
        ended.status = "ended"
        XCTAssertFalse(monitor.isDue(ended, now: now))
    }

    func testPushedAlertsGoToTheInboxWithoutASecondNotification() async throws {
        let (_, monitor, inbox, center) = try make("monitor-pushed")
        StubServer.handler = { path, _ in
            path.hasSuffix("/monitor/alerts") ? (200, ["alerts": [["id": 3, "ts": 1.0, "title": "t", "body": "b", "pushed": 1]]]) : (404, [:])
        }
        await monitor.pullAlerts()
        XCTAssertEqual(inbox.all().map(\.identifier), ["monitor-3"])
        XCTAssertTrue(center.added.isEmpty)
    }
}
