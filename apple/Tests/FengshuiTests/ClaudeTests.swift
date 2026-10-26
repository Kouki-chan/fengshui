import FengshuiKit
import GRDB
import XCTest
@testable import Fengshui

/// Records every request body and replays scripted responses.
final class MockTransport: MessagesTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var bodies: [String] = []          // JSON strings, for the privacy scan
    private(set) var betas: [[String]] = []
    var script: [(Int, [String: Any]) -> [String: Any]] = []
    var fail: Error?

    func send(_ data: Data, betas b: [String]) async throws -> Data {
        let body = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let json = String(data: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), encoding: .utf8)!
        let i: Int = lock.withLock { bodies.append(json); betas.append(b); return bodies.count - 1 }
        AllRequests.add(json)
        if let fail { throw fail }
        let f = i < script.count ? script[i] : script.last!
        return try JSONSerialization.data(withJSONObject: f(i, body))
    }

    static func toolUse(_ calls: [(String, [String: Any])], thinking: Bool = true) -> [String: Any] {
        var content: [[String: Any]] = thinking ? [["type": "thinking", "thinking": "", "signature": "sig-abc"]] : []
        for (k, c) in calls.enumerated() { content.append(["type": "tool_use", "id": "toolu_\(k)_\(c.0)", "name": c.0, "input": c.1]) }
        return ["stop_reason": "tool_use", "content": content, "usage": ["input_tokens": 1000, "output_tokens": 50]]
    }

    static func final(_ text: String, stop: String = "end_turn") -> [String: Any] {
        ["stop_reason": stop, "content": [["type": "text", "text": text]], "usage": ["input_tokens": 1500, "output_tokens": 200]]
    }
}

/// Every request body any test built (privacy scan at the end of the suite).
enum AllRequests {
    nonisolated(unsafe) static var bodies: [String] = []
    static let lock = NSLock()
    static func add(_ s: String) { lock.withLock { bodies.append(s) } }
}

final class ClaudeTests: XCTestCase {
    static let rawMarkers = ["raw_chunks", "raw_minute_features", "enmo_mg", "mag_sd_mg", "cadence_hz", "active_frac",
                             "gyro_rms_dps", "heading_change_deg", "payload", "fsr1"]

    func scenarioDB() throws -> (AppDatabase, Scenario) {
        let src = repoRoot.appendingPathComponent("build/parity/mac.sqlite")
        guard FileManager.default.fileExists(atPath: src.path) else { throw XCTSkip("run engine/tests/parity.py first") }
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID()).sqlite")
        try FileManager.default.copyItem(at: src, to: dst)
        return (try AppDatabase(path: dst.path), try Scenario.load("typical_week", bundle: Bundle(for: Self.self)))
    }

    func tools(_ db: AppDatabase, _ sc: Scenario) throws -> ClaudeTools {
        try ClaudeTools(dbPath: db.path, timeZone: TimeZone(identifier: sc.tz)!)
    }

    func json(_ s: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:] }

    // MARK: Tools on a scenario database

    func testEachTool() throws {
        let (db, sc) = try scenarioDB()
        let t = try tools(db, sc)
        let avail = json(try t.run("list_available_data", [:]))
        XCTAssertTrue((avail["labels"] as! [[String: Any]]).contains { $0["label"] as? String == "heart_rate" })
        XCTAssertTrue((avail["inference_kinds"] as! [[String: Any]]).contains { $0["kind"] as? String == "wind_down_plan" })

        let bouts = json(try t.run("get_inferences", ["kind": "activity_bout", "start": "2026-10-23", "end": "2026-10-23"]))
        let rows = bouts["rows"] as! [[String: Any]]
        XCTAssertGreaterThan(rows.count, 10)
        XCTAssertTrue(rows.contains { $0["label"] as? String == "walking" && $0["place"] as? String == "near Work" })

        let day = json(try t.run("get_daily_summary", ["date": "2026-10-23"]))
        XCTAssertNotNil(day["last_night_sleep"] as? [String: Any])
        XCTAssertNotNil(day["activity"] as? [String: Any])
        XCTAssertFalse((day["visits"] as! [Any]).isEmpty)

        let hr = json(try t.run("get_series", ["label": "heart_rate", "start": "2026-10-20", "end": "2026-10-23", "bucket": "1h", "agg": "avg"]))
        let pts = hr["points"] as! [[Any]]
        XCTAssertGreaterThan(pts.count, 40)
        XCTAssertTrue(pts.allSatisfy { ($0[1] as! Double) > 40 && ($0[1] as! Double) < 190 })
        let steps = json(try t.run("get_series", ["label": "step_count", "start": "2026-10-20", "end": "2026-10-23", "bucket": "1d", "agg": "sum"]))
        XCTAssertEqual((steps["points"] as! [[Any]]).count, 4)

        let nights = json(try t.run("get_sleep_nights", ["start": "2026-10-17", "end": "2026-10-23"]))
        XCTAssertEqual((nights["nights"] as! [[String: Any]]).count, 7)

        let visits = json(try t.run("get_visits", ["start": "2026-10-23", "end": "2026-10-23"]))
        let v = visits["visits"] as! [[String: Any]]
        XCTAssertTrue(v.contains { $0["place"] as? String == "Work" })
        XCTAssertFalse(visits.description.contains("lat"))         // names only, no coordinates

        let screen = json(try t.run("get_screen_events", ["start": "2026-10-23", "end": "2026-10-23"]))
        XCTAssertEqual((screen["events"] as! [Any]).count, 0)
    }

    func testToolErrorsAndLimits() throws {
        let (db, sc) = try scenarioDB()
        let t = try tools(db, sc)
        XCTAssertThrowsError(try t.run("get_series", ["label": "heart_rate", "start": "2026-01-01", "end": "2026-10-23", "bucket": "5m", "agg": "avg"]))
        XCTAssertThrowsError(try t.run("get_visits", ["start": "yesterday", "end": "2026-10-23"]))
        XCTAssertThrowsError(try t.run("read_raw", [:]))
        let big = try t.run("get_inferences", ["kind": "activity_bout", "start": "2026-09-27", "end": "2026-10-24"])
        XCTAssertLessThanOrEqual(big.count, ClaudeTools.maxResultChars + 80)
    }

    /// Gate: no tool can read raw_chunks or raw_minute_features.
    func testNoToolCanReadRawTables() throws {
        let (db, sc) = try scenarioDB()
        XCTAssertGreaterThan(try db.count("SELECT COUNT(*) FROM raw_chunks"), 1000)        // raw data is there…
        let t = try tools(db, sc)
        for sql in ["SELECT * FROM raw_chunks", "select payload from RAW_CHUNKS", "SELECT * FROM raw_minute_features",
                    "SELECT enmo_mg FROM raw_minute_features"] {
            XCTAssertThrowsError(try t.query.rows(sql), sql)
        }
        XCTAssertFalse(ReadOnlyQuery.allowed("SELECT * FROM processed_samples JOIN raw_chunks USING (minute_id)"))
        // The tool connection is read-only.
        XCTAssertThrowsError(try t.query.queue.write { try $0.execute(sql: "DELETE FROM inferences") })
        // …and no tool output mentions it, for every tool.
        let calls: [(String, [String: Any])] = [
            ("list_available_data", [:]),
            ("get_inferences", ["kind": "activity_day", "start": "2026-10-01", "end": "2026-10-24"]),
            ("get_daily_summary", ["date": "2026-10-23"]),
            ("get_series", ["label": "heart_rate", "start": "2026-10-23", "end": "2026-10-23", "bucket": "15m", "agg": "max"]),
            ("get_sleep_nights", ["start": "2026-10-01", "end": "2026-10-24"]),
            ("get_visits", ["start": "2026-10-20", "end": "2026-10-24"]),
            ("get_screen_events", ["start": "2026-10-20", "end": "2026-10-24"])]
        for (name, input) in calls {
            let out = try t.run(name, input)
            for m in Self.rawMarkers { XCTAssertFalse(out.contains(m), "\(name) output contains \(m)") }
        }
    }

    // MARK: Tool loop (mocked API)

    func assistant(_ db: AppDatabase, _ sc: Scenario, _ mock: MockTransport, model: String = ClaudeAssistant.defaultModel) throws -> ClaudeAssistant {
        ClaudeAssistant(db: db, tools: try tools(db, sc), transport: mock, clock: FixedClock(Date(timeIntervalSince1970: sc.now)),
                        timeZone: TimeZone(identifier: sc.tz)!, model: model)
    }

    func testToolLoopSeveralRoundsAndLogging() async throws {
        let (db, sc) = try scenarioDB()
        let mock = MockTransport()
        mock.script = [
            { _, _ in MockTransport.toolUse([("list_available_data", [:]),
                                             ("get_sleep_nights", ["start": "2026-10-10", "end": "2026-10-23"])]) },
            { _, _ in MockTransport.toolUse([("get_daily_summary", ["date": "2026-10-23"])]) },
            { _, _ in MockTransport.final("You slept about 7 h 20 min on average (sleep nights).") },
        ]
        let a = try assistant(db, sc, mock)
        let ans = await a.ask("How did I sleep this week compared with last week?")
        XCTAssertNil(ans.error)
        XCTAssertEqual(mock.bodies.count, 3)
        XCTAssertEqual(ans.toolCalls, ["list_available_data", "get_sleep_nights", "get_daily_summary"])
        XCTAssertEqual(ans.inputTokens, 3500)
        XCTAssertEqual(ans.outputTokens, 300)
        // Request 2: assistant turn appended unchanged (thinking block kept), then ONE user turn with both results.
        let msgs = json(mock.bodies[1])["messages"] as! [[String: Any]]
        XCTAssertEqual(msgs.map { $0["role"] as! String }, ["user", "assistant", "user"])
        let asst = msgs[1]["content"] as! [[String: Any]]
        XCTAssertEqual(asst.first?["type"] as? String, "thinking")
        XCTAssertEqual(asst.first?["signature"] as? String, "sig-abc")
        let results = msgs[2]["content"] as! [[String: Any]]
        XCTAssertEqual(results.map { $0["type"] as! String }, ["tool_result", "tool_result"])
        XCTAssertEqual(results.map { $0["tool_use_id"] as! String }, ["toolu_0_list_available_data", "toolu_1_get_sleep_nights"])
        // Logged.
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM ai_log"), 1)
        let calls = try await db.writer.read { try String.fetchOne($0, sql: "SELECT tool_calls_json FROM ai_log") } ?? ""
        XCTAssertTrue(calls.contains("get_sleep_nights") && calls.contains("2026-10-10"))
        XCTAssertEqual(try db.count("SELECT input_tokens FROM ai_log"), 3500)
    }

    func testRequestShape() async throws {
        let (db, sc) = try scenarioDB()
        let mock = MockTransport()
        mock.script = [{ _, _ in MockTransport.final("ok") }]
        _ = await (try assistant(db, sc, mock)).ask("How active was I today?")
        let body = json(mock.bodies[0])
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5")
        XCTAssertEqual((body["tool_choice"] as? [String: Any])?["type"] as? String, "auto")   // forced choice 400s on this model
        XCTAssertNil(body["temperature"])
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertEqual(mock.betas[0], [ClaudeAssistant.fallbackBeta])
        // 7 data tools (spec §13) + 3 report tools (DECISIONS D-20).
        XCTAssertEqual((body["tools"] as! [[String: Any]]).compactMap { $0["name"] as? String }.suffix(3),
                       ["list_report_labels", "propose_report_labels", "create_report"])
        XCTAssertEqual((body["tools"] as! [Any]).count, 10)
        XCTAssertTrue(((body["system"] as! [[String: Any]])[0]["text"] as! String).hasPrefix("You are Fengshui"))
        // Haiku: no server-side fallback.
        let mock2 = MockTransport()
        mock2.script = [{ _, _ in MockTransport.final("ok") }]
        _ = await (try assistant(db, sc, mock2, model: ClaudeAssistant.smokeTestModel)).ask("x")
        XCTAssertNil(json(mock2.bodies[0])["fallbacks"])
        XCTAssertEqual(mock2.betas[0], [])
    }

    func testRoundCap() async throws {
        let (db, sc) = try scenarioDB()
        let mock = MockTransport()
        mock.script = [{ _, _ in MockTransport.toolUse([("list_available_data", [:])]) }]   // never stops asking
        let ans = await (try assistant(db, sc, mock)).ask("loop forever")
        XCTAssertLessThanOrEqual(mock.bodies.count, ClaudeAssistant.maxToolRounds + 2)
        XCTAssertEqual(ans.error, "tool_round_limit")
        let last = json(mock.bodies.last!)["messages"] as! [[String: Any]]
        let lastResult = (last.last!["content"] as! [[String: Any]])[0]
        XCTAssertEqual(lastResult["is_error"] as? Bool, true)
        XCTAssertTrue((lastResult["content"] as! String).contains("Tool budget reached"))
    }

    func testOutputCap() async throws {
        let (db, sc) = try scenarioDB()
        let mock = MockTransport()
        let big: [String: Any] = ["kind": "activity_bout", "start": "2026-09-27", "end": "2026-10-24"]
        mock.script = Array(repeating: { _, _ in MockTransport.toolUse([("get_inferences", big)]) }, count: 6)
            + [{ _, _ in MockTransport.final("done") }]
        _ = await (try assistant(db, sc, mock)).ask("lots of data")
        // Total tool output sent stays within the cap, then the model is told the budget is used up.
        let msgs = json(mock.bodies.last!)["messages"] as! [[String: Any]]
        let outputs = msgs.filter { $0["role"] as? String == "user" }.flatMap { ($0["content"] as! [[String: Any]]) }
            .filter { $0["type"] as? String == "tool_result" }
        let total = outputs.map { ($0["content"] as! String).count }.reduce(0, +)
        XCTAssertLessThanOrEqual(total, ClaudeAssistant.maxToolChars + 2_000)
        XCTAssertTrue(outputs.contains { ($0["content"] as! String).contains("budget") })
    }

    func testErrorsRefusalAndBadToolsAreHandled() async throws {
        let (db, sc) = try scenarioDB()
        let m1 = MockTransport()
        m1.fail = AnthropicHTTP.APIError(status: 401, type: "authentication_error", message: "invalid x-api-key")
        let a1 = await (try assistant(db, sc, m1)).ask("q1")
        XCTAssertTrue(a1.error?.contains("401") ?? false)
        let m2 = MockTransport()
        m2.script = [{ _, _ in MockTransport.final("", stop: "refusal") }]
        let a2 = await (try assistant(db, sc, m2)).ask("q2")
        XCTAssertEqual(a2.error, "refusal")
        let m3 = MockTransport()
        m3.script = [{ _, _ in MockTransport.toolUse([("fetch_sensor_dump", [:])]) }, { _, _ in MockTransport.final("sorry") }]
        let a3 = await (try assistant(db, sc, m3)).ask("q3")
        XCTAssertNil(a3.error)
        let r = (json(m3.bodies[1])["messages"] as! [[String: Any]]).last!["content"] as! [[String: Any]]
        XCTAssertEqual(r[0]["is_error"] as? Bool, true)
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM ai_log WHERE error IS NOT NULL"), 2)
    }

    func testHTTPHeadersAndRetry() async throws {
        StubServer.requests = []
        nonisolated(unsafe) var seen: [URLRequest] = []
        HeaderStub.onRequest = { seen.append($0) }
        HeaderStub.statuses = [529, 200]
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [HeaderStub.self]
        let http = AnthropicHTTP(apiKey: "sk-test", session: URLSession(configuration: c))
        let r = try await http.send(Data(#"{"model":"m","messages":[]}"#.utf8), betas: ["server-side-fallback-2026-07-01"])
        XCTAssertEqual(json(String(decoding: r, as: UTF8.self))["ok"] as? Bool, true)
        XCTAssertEqual(seen.count, 2)                                   // retried the 529
        let h = seen[0].allHTTPHeaderFields ?? [:]
        XCTAssertEqual(h["x-api-key"], "sk-test")
        XCTAssertEqual(h["anthropic-version"], "2026-10-21")
        XCTAssertEqual(h["anthropic-beta"], "server-side-fallback-2026-07-01")
        XCTAssertEqual(seen[0].url?.absoluteString, "https://api.anthropic.com/v1/messages")
    }

    // MARK: Preset questions

    func testPresetQuestionsAndScheduling() throws {
        let db = try AppDatabase.temporary("questions")
        let tz = TimeZone(identifier: "America/New_York")!
        let clock = FixedClock(ISO8601DateFormatter().date(from: "2026-10-25T22:00:00Z")!)    // Sun 18:00 local
        let s = AIQuestionStore(db: db, clock: clock)
        try s.seedIfNeeded(); try s.seedIfNeeded()
        XCTAssertEqual(try s.all().map(\.text), AIQuestionStore.seeds)
        XCTAssertNil(AIQuestionStore.parse("weekly:funday:19:00"))
        XCTAssertEqual(AIQuestionStore.parse("weekly:sun:19:00"), .init(weekday: 1, hour: 19, minute: 0))
        XCTAssertThrowsError(try s.add("bad", schedule: "hourly"))
        let id = try s.add("Weekly recap", schedule: "weekly:sun:19:00")
        XCTAssertTrue(try s.due(tz: tz).isEmpty)                  // first sight: starts from now
        clock.advance(by: 3600 + 60)                               // Sun 19:01 local
        XCTAssertEqual(try s.due(tz: tz).map(\.id), [id])
        try s.markRun(id)
        XCTAssertTrue(try s.due(tz: tz).isEmpty)
        // One week later; US daylight saving ends on 1 Nov, so 19:01 local is 7 days + 1 h later.
        clock.advance(by: 7 * 86400)
        XCTAssertTrue(try s.due(tz: tz).isEmpty)                  // 18:01 EST: not yet
        clock.advance(by: 3600)
        XCTAssertEqual(try s.due(tz: tz).map(\.id), [id])
        var q = try s.all().first { $0.id == id }!
        q.enabled = false
        try s.update(q)
        XCTAssertTrue(try s.due(tz: tz).isEmpty)
    }

    func testScheduledAnswerDeliveredAsNotification() async throws {
        let (db, sc) = try scenarioDB()
        let mock = MockTransport()
        mock.script = [{ _, _ in MockTransport.final("Wind down at 22:12 because …") }]
        let clock = FixedClock(Date(timeIntervalSince1970: sc.now))
        let store = AIQuestionStore(db: db, clock: clock)
        let id = try store.add("Tonight?", schedule: "daily:20:30")
        _ = try store.due(tz: TimeZone(identifier: sc.tz)!)                     // first sight
        try await db.writer.write { try $0.execute(sql: "UPDATE preferences SET value_json = ? WHERE key = ?",
                                                    arguments: ["{\"\(id)\":0}", AIQuestionStore.lastRunKey]) }
        let center = FakeNotificationCenter()
        let a = try assistant(db, sc, mock)
        let runner = ScheduledQuestions(store: store, assistant: { a }, notifications: center, timeZone: TimeZone(identifier: sc.tz)!)
        let n = await runner.runDue()
        XCTAssertEqual(n, 1)
        XCTAssertEqual(center.added.first?.title, "Tonight?")
        XCTAssertEqual(center.added.first?.userInfo["kind"], "ai_answer")
        XCTAssertNotNil(center.added.first?.userInfo["ai_log_id"])
    }

    /// Gate: privacy scan of every request body built in these tests.
    func testZZPrivacyScanOfAllRequestBodies() async throws {
        // Ensure at least one full loop ran in this process (test order is alphabetical).
        if AllRequests.bodies.isEmpty { try await testToolLoopSeveralRoundsAndLogging() }
        XCTAssertFalse(AllRequests.bodies.isEmpty)
        for body in AllRequests.lock.withLock({ AllRequests.bodies }) {
            for m in Self.rawMarkers { XCTAssertFalse(body.contains(m), "request body contains raw-data field \(m)") }
        }
    }
}

final class HeaderStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var onRequest: (URLRequest) -> Void = { _ in }
    nonisolated(unsafe) static var statuses: [Int] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.onRequest(request)
        let code = Self.statuses.isEmpty ? 200 : Self.statuses.removeFirst()
        let body = code == 200 ? #"{"ok":true}"# : #"{"error":{"type":"overloaded_error","message":"busy"}}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
