import FengshuiKit
import Foundation

/// The owner's Claude Managed Agent as the assistant backend (DECISIONS D-22). The agent loop
/// runs on Anthropic's side; the app's tools are **custom tools** the agent calls and this phone
/// answers (processed data only, same read-only ClaudeTools and report actions as the direct
/// backend). The agent resource is never modified: tools are added to sessions only.
protocol ManagedTransport: Sendable {
    /// JSON request to /v1/...; returns the response body.
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data
    /// Opens the session's SSE stream (returns once connected) and yields each event's JSON.
    func events(_ sessionID: String) async throws -> AsyncThrowingStream<Data, Error>
}

struct ManagedAgentsHTTP: ManagedTransport {
    static let base = URL(string: "https://api.anthropic.com")!
    static let beta = "managed-agents-2026-04-01"
    let apiKey: String
    let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    private func req(_ method: String, _ path: String) -> URLRequest {
        var r = URLRequest(url: Self.base.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue(AnthropicHTTP.version, forHTTPHeaderField: "anthropic-version")
        r.setValue(Self.beta, forHTTPHeaderField: "anthropic-beta")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        return r
    }

    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        var r = req(method, path)
        r.httpBody = body
        r.timeoutInterval = 60
        let (data, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let e = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? [String: Any]
            throw AnthropicHTTP.APIError(status: code, type: e?["type"] as? String ?? "error",
                                         message: e?["message"] as? String ?? String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    func events(_ sessionID: String) async throws -> AsyncThrowingStream<Data, Error> {
        var r = req("GET", "v1/sessions/\(sessionID)/events/stream")
        r.setValue("text/event-stream", forHTTPHeaderField: "accept")
        r.timeoutInterval = 300
        let (bytes, resp) = try await session.bytes(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw AnthropicHTTP.APIError(status: code, type: "stream_error", message: "event stream HTTP \(code)")
        }
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var parser = SSEParser()
                    for try await line in bytes.lines {
                        if let event = parser.feed(line) { cont.yield(event) }
                    }
                    if let event = parser.flush() { cont.yield(event) }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

/// Server-sent events → one JSON payload per event. `AsyncBytes.lines` drops the blank lines
/// that end SSE events, so an event is emitted as soon as its `data:` lines form valid JSON
/// (Anthropic sends each event as one JSON line), or when the next `event:` line starts.
struct SSEParser {
    private var data = ""

    mutating func feed(_ line: String) -> Data? {
        if line.hasPrefix("data:") {
            data += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if (try? JSONSerialization.jsonObject(with: Data(data.utf8))) != nil { return flush() }
            return nil
        }
        // A blank line (if it arrives) or the next event's header ends the current one.
        if line.isEmpty || line.hasPrefix("event:") { return flush() }
        return nil                                    // comments (":"), id:, retry:
    }

    mutating func flush() -> Data? {
        guard !data.isEmpty else { return nil }
        defer { data = "" }
        return Data(data.utf8)
    }
}

/// Where the agent lives. IDs aren't secrets but are account-specific: they come from the
/// gitignored Local.xcconfig (via Info.plist) or Settings → Claude, never from the repo.
struct ManagedAgentConfig: Sendable, Codable, Equatable {
    static let key = "managed_agent"
    var enabled = true
    var agentID = ""
    /// The Ask chat continues in this session; replaced automatically if it ends.
    var chatSessionID = ""
    var environmentID = ""
    /// The agent's display name, fetched once (optional so older saved settings still decode).
    var agentName: String?

    var isUsable: Bool { enabled && agentID.hasPrefix("agent_") }

    static func load(_ db: AppDatabase) -> ManagedAgentConfig {
        if let c = (try? db.preference(key, as: ManagedAgentConfig.self)) ?? nil { return c }
        let info = Bundle.main.infoDictionary ?? [:]
        let s = { (k: String) in (info[k] as? String).map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }
        return ManagedAgentConfig(enabled: true, agentID: s("FengshuiAgentID"), chatSessionID: s("FengshuiAgentSessionID"))
    }

    func save(_ db: AppDatabase) { try? db.setPreference(Self.key, self) }
}

actor ManagedAssistant: Assistant {
    static let maxToolCalls = 24
    static let deadline: Duration = .seconds(300)

    private let db: AppDatabase
    private let tools: ClaudeTools
    private let actions: AssistantActions?
    private let transport: ManagedTransport
    private let clock: Clock
    private let timeZone: TimeZone
    private let log: EventLog
    /// true: the persistent Ask chat session; false: a fresh session for this request.
    private let chat: Bool
    private var config: ManagedAgentConfig

    init(db: AppDatabase, tools: ClaudeTools, actions: AssistantActions?, transport: ManagedTransport, clock: Clock,
         timeZone: TimeZone, log: EventLog, config: ManagedAgentConfig, chat: Bool) {
        self.db = db
        self.tools = tools
        self.actions = actions
        self.transport = transport
        self.clock = clock
        self.timeZone = timeZone
        self.log = log
        self.config = config
        self.chat = chat
    }

    /// The app's tools as Managed Agents custom tools.
    static var customTools: [[String: Any]] {
        ClaudeTools.definitions.map {
            ["type": "custom", "name": $0["name"]!, "description": $0["description"]!, "input_schema": $0["input_schema"]!]
        }
    }

    static var customToolNames: Set<String> { Set(ClaudeTools.definitions.compactMap { $0["name"] as? String }) }

    private func json(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        let data = try await transport.request(method, path, body: try body.map { try JSONSerialization.data(withJSONObject: $0) })
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// The agent's own tools minus any named like ours, plus ours.
    private func sessionTools(existing: [[String: Any]]) -> [[String: Any]] {
        existing.filter { !Self.customToolNames.contains($0["name"] as? String ?? "") } + Self.customTools
    }

    private func environmentID() async throws -> String {
        if !config.environmentID.isEmpty { return config.environmentID }
        guard !config.chatSessionID.isEmpty else {
            throw ClaudeTools.ToolError(description: "no environment: set a session ID in Settings → Claude")
        }
        let s = try await json("GET", "v1/sessions/\(config.chatSessionID)")
        guard let env = s["environment_id"] as? String else { throw ClaudeTools.ToolError(description: "session has no environment") }
        config.environmentID = env
        config.save(db)
        return env
    }

    /// "Managed Agent “FengShui Agent” (agent_…) · session sesn_…" for reports and the Ask tab.
    private func answeredBy(_ sessionID: String?) -> String {
        let name = config.agentName.map { "“\($0)” " } ?? ""
        return "Managed Agent \(name)(\(config.agentID))" + (sessionID.map { " · session \($0)" } ?? "")
    }

    private func rememberName(_ agent: [String: Any]) {
        if let n = agent["name"] as? String, n != config.agentName { config.agentName = n; config.save(db) }
    }

    private func newSession(title: String) async throws -> String {
        let agent = try await json("GET", "v1/agents/\(config.agentID)")
        rememberName(agent)
        let tools = sessionTools(existing: agent["tools"] as? [[String: Any]] ?? [])
        let s = try await json("POST", "v1/sessions", [
            "agent": ["type": "agent_with_overrides", "id": config.agentID, "tools": tools],
            "environment_id": try await environmentID(), "title": title,
        ])
        guard let id = s["id"] as? String else { throw ClaudeTools.ToolError(description: "session not created") }
        return id
    }

    /// The chat session, with the app's tools added (session-local), or a new one if it ended.
    private func chatSession() async throws -> String {
        if !config.chatSessionID.isEmpty, let s = try? await json("GET", "v1/sessions/\(config.chatSessionID)"),
           (s["status"] as? String) != "terminated", s["archived_at"] as? String == nil {
            if let env = s["environment_id"] as? String, config.environmentID != env { config.environmentID = env; config.save(db) }
            let have = ((s["agent"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
            let names = Set(have.compactMap { $0["name"] as? String })
            if !Self.customToolNames.isSubset(of: names) {
                // Full replacement of the session's tools: keep everything it had, add ours.
                _ = try await json("POST", "v1/sessions/\(config.chatSessionID)", ["agent": ["tools": sessionTools(existing: have)]])
                log.add("managed_tools", "added \(Self.customToolNames.subtracting(names).count) tools to the chat session")
            }
            return config.chatSessionID
        }
        let id = try await newSession(title: "Fengshui chat")
        log.add("managed_session", "chat session replaced")
        config.chatSessionID = id
        config.save(db)
        return id
    }

    func ask(_ question: String) async -> ClaudeAssistant.Answer {
        let now = clock.now
        let box = Box()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.run(question, now: now, box: box) }
                group.addTask {
                    try await Task.sleep(for: Self.deadline)
                    throw ClaudeTools.ToolError(description: "the agent took longer than 5 minutes")
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            box.answer.error = "\(error)"
            if box.answer.text.isEmpty { box.answer.text = "Couldn't reach your agent: \(error)" }
        }
        var answer = box.answer
        if answer.answeredBy == nil { answer.answeredBy = answeredBy(nil) }
        answer.logID = ClaudeAssistant.log(db: db, model: "managed:\(config.agentID)", question: question, calls: box.calls,
                                           answer: answer, at: now)
        return answer
    }

    /// Results of one run, shared with the deadline task group (only `run` writes to it).
    private final class Box: @unchecked Sendable {
        var answer = ClaudeAssistant.Answer(text: "")
        var calls: [[String: Any]] = []
    }

    private func run(_ question: String, now: Date, box: Box) async throws {
        if config.agentName == nil, let agent = try? await json("GET", "v1/agents/\(config.agentID)") { rememberName(agent) }
        let sid = chat ? try await chatSession() : try await newSession(title: "Fengshui: \(question.prefix(60))")
        box.answer.answeredBy = answeredBy(sid)
        // Stream first, then send: events before the stream opens would arrive as one late batch.
        let stream = try await transport.events(sid)
        let message: [String: Any] = ["events": [[
            "type": "user.message",
            "content": [["type": "text", "text": "Now: \(ClaudeAssistant.localDate(now, timeZone)) (\(timeZone.identifier))."],
                        ["type": "text", "text": question]],
        ]]]
        do {
            _ = try await json("POST", "v1/sessions/\(sid)/events", message)
        } catch let e as AnthropicHTTP.APIError where e.status == 400 && e.message.contains("waiting on responses") {
            // An earlier turn is stuck on a request this app never answered (it was closed, or
            // lost the stream). Stop that turn, then ask again.
            log.add("managed_recover", "interrupting a stuck turn")
            _ = try await json("POST", "v1/sessions/\(sid)/events", ["events": [["type": "user.interrupt"]]])
            try await Task.sleep(for: .seconds(1))
            _ = try await json("POST", "v1/sessions/\(sid)/events", message)
        }
        var texts: [String] = []
        var toolChars = 0
        // Ignore what belongs to an earlier turn (e.g. the interrupt's idle) until our message is echoed.
        var started = false
        for try await data in stream {
            guard let ev = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let type = ev["type"] as? String
            else { continue }
            if type == "user.message" { started = true; continue }
            if !started { continue }
            switch type {
            case "agent.message":
                let t = (ev["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                texts.append(contentsOf: t)
            case "agent.custom_tool_use":
                let id = ev["id"] as? String ?? "", name = ev["name"] as? String ?? ""
                let input = ev["input"] as? [String: Any] ?? [:]
                var out: String, isError = false
                if box.answer.toolCalls.count >= Self.maxToolCalls || toolChars >= ClaudeAssistant.maxToolChars {
                    out = "Tool budget for this question is used up. Answer with the data you already have."
                    isError = true
                } else {
                    do {
                        let inputJSON = try JSONSerialization.data(withJSONObject: input)
                        if let actions, let r = try await actions.run(name: name, inputJSON: inputJSON, answeredBy: box.answer.answeredBy ?? answeredBy(sid)) {
                            out = r.output
                            if let rid = r.reportID { box.answer.reportIDs.append(rid) }
                            if let p = r.proposedLabels { box.answer.proposedLabels = p }
                        } else if name == "notify_user" {
                            // Deployment tool (served by the Mac); in the app chat the reply itself is the message.
                            out = "The person is in the app and sees your reply directly; no notification needed."
                        } else if ["create_report", "propose_report_labels"].contains(name) {
                            throw ClaudeTools.ToolError(description: "\(name) is not available here")
                        } else {
                            out = try tools.run(name, input)
                        }
                    } catch {
                        out = "Error: \(error)"
                        isError = true
                    }
                    let room = ClaudeAssistant.maxToolChars - toolChars
                    if out.count > room { out = String(out.prefix(room)) + "…[truncated: question's tool budget reached]" }
                    toolChars += out.count
                }
                box.answer.toolCalls.append(name)
                box.answer.calls.append(.init(name: name, input: input.mapValues { v in
                    (v as? [Any]).map { $0.map { "\($0)" }.joined(separator: "\n") } ?? "\(v)"
                }))
                box.calls.append(["name": name, "input": input, "output_chars": out.count, "error": isError])
                var result: [String: Any] = ["type": "user.custom_tool_result", "custom_tool_use_id": id,
                                             "content": [["type": "text", "text": out]]]
                if isError { result["is_error"] = true }
                _ = try await json("POST", "v1/sessions/\(sid)/events", ["events": [result]])
            case "span.model_request_end":
                let u = ev["model_usage"] as? [String: Any] ?? [:]
                box.answer.inputTokens += (u["input_tokens"] as? Int ?? 0) + (u["cache_read_input_tokens"] as? Int ?? 0)
                    + (u["cache_creation_input_tokens"] as? Int ?? 0)
                box.answer.outputTokens += u["output_tokens"] as? Int ?? 0
            case "session.error":
                let e = ev["error"] as? [String: Any]
                box.answer.error = (e?["message"] as? String) ?? "session error"
            case "session.status_terminated":
                box.answer.text = texts.joined(separator: "\n\n")
                if box.answer.text.isEmpty { box.answer.text = "Your agent's session ended without an answer." }
                if chat { config.chatSessionID = ""; config.save(db) }
                return
            case "session.status_idle":
                let stop = (ev["stop_reason"] as? [String: Any])?["type"] as? String
                if stop == "requires_action" { continue }        // waiting on our tool result or a confirmation
                box.answer.text = texts.joined(separator: "\n\n")
                if stop == "budget_reached" { box.answer.error = "budget_reached" }
                if box.answer.text.isEmpty { box.answer.text = "Your agent finished without a reply." }
                return
            default:
                continue
            }
        }
        box.answer.text = texts.joined(separator: "\n\n")
        throw ClaudeTools.ToolError(description: "event stream closed before the agent finished")
    }
}
