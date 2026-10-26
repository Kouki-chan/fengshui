import FengshuiKit
import GRDB
import XCTest
@testable import Fengshui

/// Scripted Managed Agents API: answers REST calls from a handler and plays one event list per stream.
final class MockManaged: ManagedTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [(method: String, path: String, body: [String: Any])] = []
    var handler: (String, String, [String: Any]) -> [String: Any] = { _, _, _ in [:] }
    var streamEvents: [[String: Any]] = []
    private(set) var streamOpenedBeforeSend: Bool?
    /// Simulates a session stuck on an unanswered tool call: the first user.message is refused.
    var stuck = false

    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        let b = body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        let refuse: Bool = lock.withLock {
            requests.append((method, path, b))
            let isMessage = (b["events"] as? [[String: Any]])?.first?["type"] as? String == "user.message"
            if stuck && isMessage { stuck = false; return true }
            return false
        }
        if refuse {
            throw AnthropicHTTP.APIError(status: 400, type: "invalid_request_error",
                                         message: "Invalid user.message event at events[0]: waiting on responses to events [sevt_old]")
        }
        let out: [String: Any] = lock.withLock { handler(method, path, b) }
        return try JSONSerialization.data(withJSONObject: out)
    }

    func events(_ sessionID: String) async throws -> AsyncThrowingStream<Data, Error> {
        lock.withLock {
            if streamOpenedBeforeSend == nil {
                streamOpenedBeforeSend = !requests.contains { $0.path.hasSuffix("/events") && $0.method == "POST" }
            }
        }
        let events = streamEvents
        return AsyncThrowingStream { cont in
            for e in events { cont.yield(try! JSONSerialization.data(withJSONObject: e)) }
            cont.finish()
        }
    }

    var sentEvents: [[String: Any]] {
        lock.withLock { requests.filter { $0.path.hasSuffix("/events") }.flatMap { $0.body["events"] as? [[String: Any]] ?? [] } }
    }
}

final class ManagedAgentTests: XCTestCase {
    func setup(_ name: String, session: [String: Any]? = nil) throws -> (AppDatabase, MockManaged, Scenario, ReportStore) {
        let src = repoRoot.appendingPathComponent("build/parity/mac.sqlite")
        guard FileManager.default.fileExists(atPath: src.path) else { throw XCTSkip("run engine/tests/parity.py first") }
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("managed-\(UUID()).sqlite")
        try FileManager.default.copyItem(at: src, to: dst)
        let db = try AppDatabase(path: dst.path)
        let sc = try Scenario.load("typical_week", bundle: Bundle(for: Self.self))
        let clock = FixedClock(Date(timeIntervalSince1970: sc.now))
        let reports = ReportStore(db: db, clock: clock, timeZone: TimeZone(identifier: sc.tz)!,
                                  inbox: InboxStore(db: db, clock: clock, center: FakeNotificationCenter()),
                                  directory: FileManager.default.temporaryDirectory.appendingPathComponent("mr-\(UUID())"))
        let m = MockManaged()
        let existing: [[String: Any]] = [["type": "agent_toolset_20260401",
                                          "default_config": ["enabled": false], "configs": [["name": "read", "enabled": true]]]]
        m.handler = { method, path, _ in
            switch (method, path) {
            case ("GET", "v1/sessions/sesn_chat"):
                return session ?? ["id": "sesn_chat", "status": "idle", "environment_id": "env_9", "agent": ["tools": existing]]
            case ("GET", "v1/agents/agent_me"): return ["id": "agent_me", "tools": existing]
            case ("POST", "v1/sessions"): return ["id": "sesn_new", "status": "idle"]
            default: return [:]
            }
        }
        m.streamEvents = [
            // Left over from an earlier turn: must not end this one.
            ["type": "session.status_idle", "stop_reason": ["type": "end_turn"]],
            ["type": "user.message"],
            ["type": "session.status_running"],
            ["type": "agent.custom_tool_use", "id": "sevt_1", "name": "list_available_data", "input": [:]],
            ["type": "session.status_idle", "stop_reason": ["type": "requires_action", "event_ids": ["sevt_1"]]],
            ["type": "span.model_request_end", "model_usage": ["input_tokens": 900, "output_tokens": 120, "cache_read_input_tokens": 100]],
            ["type": "agent.message", "content": [["type": "text", "text": "You slept about 7 hours a night."]]],
            ["type": "session.status_idle", "stop_reason": ["type": "end_turn"]],
        ]
        return (db, m, sc, reports)
    }

    func assistant(_ db: AppDatabase, _ m: MockManaged, _ sc: Scenario, _ reports: ReportStore, chat: Bool) throws -> ManagedAssistant {
        let tz = TimeZone(identifier: sc.tz)!
        let cfg = ManagedAgentConfig(enabled: true, agentID: "agent_me", chatSessionID: "sesn_chat")
        cfg.save(db)
        return ManagedAssistant(db: db, tools: try ClaudeTools(dbPath: db.path, timeZone: tz), actions: ReportActions(store: reports),
                                transport: m, clock: FixedClock(Date(timeIntervalSince1970: sc.now)), timeZone: tz,
                                log: EventLog(), config: cfg, chat: chat)
    }

    func testChatContinuesInTheGivenSessionAndToolsRunOnThePhone() async throws {
        let (db, m, sc, reports) = try setup("chat")
        let ans = await (try assistant(db, m, sc, reports, chat: true)).ask("How did I sleep?")
        XCTAssertNil(ans.error)
        XCTAssertEqual(ans.text, "You slept about 7 hours a night.")
        XCTAssertEqual(ans.toolCalls, ["list_available_data"])
        XCTAssertEqual(ans.inputTokens, 1_000)
        XCTAssertEqual(ans.outputTokens, 120)
        XCTAssertEqual(m.streamOpenedBeforeSend, true, "stream first, then send")
        // Tools were added to the chat session only: the agent's toolset is kept, ours appended.
        let update = try XCTUnwrap(m.requests.first { $0.method == "POST" && $0.path == "v1/sessions/sesn_chat" })
        let tools = ((update.body["agent"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        XCTAssertEqual(tools.first?["type"] as? String, "agent_toolset_20260401")
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), ManagedAssistant.customToolNames)
        XCTAssertTrue(tools.dropFirst().allSatisfy { $0["type"] as? String == "custom" && $0["input_schema"] != nil })
        XCTAssertFalse(m.requests.contains { $0.path.hasPrefix("v1/agents") && $0.method == "POST" }, "the agent is never modified")
        // The message, then the tool result answering the agent's call by event id.
        let sent = m.sentEvents
        XCTAssertEqual(sent.first?["type"] as? String, "user.message")
        let result = try XCTUnwrap(sent.first { $0["type"] as? String == "user.custom_tool_result" })
        XCTAssertEqual(result["custom_tool_use_id"] as? String, "sevt_1")
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("heart_rate"))
        for marker in ClaudeTests.rawMarkers { XCTAssertFalse(text.contains(marker), marker) }
        // Logged like the direct backend.
        XCTAssertEqual(try db.int64("SELECT COUNT(*) FROM ai_log WHERE model = 'managed:agent_me'"), 1)
    }

    func testReportStepsUseAFreshSessionFromTheAgent() async throws {
        let (db, m, sc, reports) = try setup("fresh")
        _ = await (try assistant(db, m, sc, reports, chat: false)).ask("Suggest labels")
        let create = try XCTUnwrap(m.requests.first { $0.method == "POST" && $0.path == "v1/sessions" })
        let agent = try XCTUnwrap(create.body["agent"] as? [String: Any])
        XCTAssertEqual(agent["type"] as? String, "agent_with_overrides")
        XCTAssertEqual(agent["id"] as? String, "agent_me")
        XCTAssertEqual(create.body["environment_id"] as? String, "env_9", "environment taken from the chat session")
        XCTAssertTrue(m.requests.contains { $0.path == "v1/sessions/sesn_new/events" })
        XCTAssertFalse(m.requests.contains { $0.path == "v1/sessions/sesn_chat/events" }, "the chat stays clean")
    }

    func testEndedChatSessionIsReplaced() async throws {
        let (db, m, sc, reports) = try setup("ended", session: ["id": "sesn_chat", "status": "terminated", "environment_id": "env_9"])
        let ans = await (try assistant(db, m, sc, reports, chat: true)).ask("Hi")
        XCTAssertNil(ans.error)
        XCTAssertEqual(ManagedAgentConfig.load(db).chatSessionID, "sesn_new")
    }

    func testReportCreatedThroughTheAgent() async throws {
        let (db, m, sc, reports) = try setup("report")
        let tz = TimeZone(identifier: sc.tz)!
        let day = ReportData.dayString(Date(timeIntervalSince1970: sc.now), tz)
        m.streamEvents = [
            ["type": "user.message"],
            ["type": "agent.custom_tool_use", "id": "sevt_r", "name": "create_report",
             "input": ["title": "For my GP", "start": day, "end": day, "labels": ["heart_rate"], "summary": "Stable."]],
            ["type": "agent.message", "content": [["type": "text", "text": "Done."]]],
            ["type": "session.status_idle", "stop_reason": ["type": "end_turn"]],
        ]
        let ans = await (try assistant(db, m, sc, reports, chat: false)).ask("Make a report")
        let r = try XCTUnwrap(ans.reportIDs.last.flatMap(reports.record))
        XCTAssertEqual(r.title, "For my GP")
    }

    func testStuckSessionIsInterruptedThenAsked() async throws {
        let (db, m, sc, reports) = try setup("stuck")
        m.stuck = true
        let ans = await (try assistant(db, m, sc, reports, chat: true)).ask("How did I sleep?")
        XCTAssertNil(ans.error)
        XCTAssertEqual(ans.text, "You slept about 7 hours a night.")
        let types = m.sentEvents.compactMap { $0["type"] as? String }
        XCTAssertEqual(Array(types.prefix(3)), ["user.message", "user.interrupt", "user.message"])
    }

    /// Real stream bytes: `lines` drops the blank lines that end SSE events, so events must be
    /// emitted from their data lines (the bug that left the first device question unanswered).
    func testSSEParserWithoutBlankLines() {
        var p = SSEParser()
        let lines = [": ping", "event: agent.custom_tool_use", #"data: {"type":"agent.custom_tool_use","id":"sevt_1"}"#,
                     "event: session.status_idle", #"data: {"type":"session.status_idle","#,
                     #"data: "stop_reason":{"type":"requires_action"}}"#, ""]
        let out = lines.compactMap { p.feed($0) } + [p.flush()].compactMap { $0 }
        let types = out.compactMap { ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any])?["type"] as? String }
        XCTAssertEqual(types, ["agent.custom_tool_use", "session.status_idle"])
    }

    func testBackendSelection() throws {
        let db = try AppDatabase.temporary("backend")
        XCTAssertFalse(ManagedAgentConfig(enabled: true, agentID: "", chatSessionID: "").isUsable)
        XCTAssertFalse(ManagedAgentConfig(enabled: false, agentID: "agent_x", chatSessionID: "").isUsable)
        ManagedAgentConfig(enabled: true, agentID: "agent_x", chatSessionID: "sesn_y").save(db)
        XCTAssertEqual(ManagedAgentConfig.load(db).agentID, "agent_x")
    }
}
