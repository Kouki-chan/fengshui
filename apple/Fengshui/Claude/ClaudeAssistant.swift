import FengshuiKit
import Foundation
import GRDB

/// Anthropic Messages API over HTTPS (Swift has no official SDK). Behind a protocol so the
/// tool loop is tested with a mock (spec §14.2 Phase 7).
protocol MessagesTransport: Sendable {
    /// POST /v1/messages with an encoded JSON body; returns the raw JSON response.
    /// (Data, not dictionaries: it crosses actor boundaries.)
    func send(_ body: Data, betas: [String]) async throws -> Data
}

struct AnthropicHTTP: MessagesTransport {
    struct APIError: Error, CustomStringConvertible {
        let status: Int
        let type: String
        let message: String
        var retryable: Bool { status == 429 || status == 529 || status >= 500 }
        var description: String { "Anthropic API \(status) \(type): \(message)" }
    }

    static let url = URL(string: "https://api.anthropic.com/v1/messages")!
    static let version = "2026-10-21"
    let apiKey: String
    let session: URLSession
    let maxRetries = 2

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func send(_ body: Data, betas: [String]) async throws -> Data {
        var req = URLRequest(url: Self.url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.version, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if !betas.isEmpty { req.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = body
        var attempt = 0
        while true {
            do {
                let (data, resp) = try await session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                guard (200..<300).contains(code) else {
                    let e = json["error"] as? [String: Any]
                    throw APIError(status: code, type: e?["type"] as? String ?? "error",
                                   message: e?["message"] as? String ?? String(data: data, encoding: .utf8) ?? "")
                }
                return data
            } catch let e as APIError where e.retryable && attempt < maxRetries {
                attempt += 1
                try await Task.sleep(for: .seconds(Double(attempt) * 2))
            } catch let e as URLError where attempt < maxRetries && e.code != .cancelled {
                attempt += 1
                try await Task.sleep(for: .seconds(Double(attempt) * 2))
            }
        }
    }
}

/// Tools the read-only ClaudeTools can't run: they create things (report PDFs) or hand a
/// choice back to the UI. Input arrives as JSON so it can cross the actor boundary.
protocol AssistantActions: Sendable {
    /// nil = not an action tool (the loop runs it through ClaudeTools).
    func run(name: String, inputJSON: Data) async throws -> AssistantActionResult?
}

struct AssistantActionResult: Sendable {
    var output: String
    var reportID: Int64?
    var proposedLabels: [String]?
}

/// Either backend (direct Messages API or the owner's Managed Agent, DECISIONS D-22).
protocol Assistant: Sendable {
    func ask(_ question: String) async -> ClaudeAssistant.Answer
}

/// Spec §13 tool loop: max 8 tool rounds, total tool output capped (~50k chars), every
/// question logged in ai_log (question, tool calls + arguments, response, tokens, errors).
actor ClaudeAssistant: Assistant {
    struct ToolCall: Sendable, Equatable {
        var name: String
        /// Arguments as strings (arrays joined with newlines), e.g. for the question's report scope.
        var input: [String: String]
    }

    struct Answer: Sendable, Equatable {
        var text: String
        var logID: Int64?
        var error: String?
        var inputTokens = 0
        var outputTokens = 0
        var toolCalls: [String] = []
        var calls: [ToolCall] = []
        var reportIDs: [Int64] = []
        var proposedLabels: [String]?
    }

    static let systemPrompt = """
        You are Fengshui, a personal assistant that helps one person understand patterns in their own health, \
        activity, sleep and daily context. Use the tools to fetch only the data you need. Base every statement on \
        returned data and say which data you used. If data is missing or thin, say so. Don't diagnose medical \
        conditions; suggest seeing a professional for anything concerning. Be concise and practical. \
        When asked for a report for a health professional: call list_report_labels for the period, choose every label \
        relevant to the purpose, look at the data you need, write a factual summary for a clinician, then call create_report.
        """
    static let defaultModel = "claude-sonnet-5-5"
    static let smokeTestModel = "claude-haiku-5-5"
    static let modelKey = "claude_model"
    static let maxToolRounds = 8
    static let maxToolChars = 50_000
    static let maxTokens = 16_000
    /// Models with server-side refusal fallbacks ("default" routing, Claude API).
    static let fallbackModels: Set<String> = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-opus-5", "claude-fable-5-1"]
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    private let db: AppDatabase
    private let tools: ClaudeTools
    private let transport: MessagesTransport
    private let clock: Clock
    private let timeZone: TimeZone
    private let actions: AssistantActions?
    let model: String

    init(db: AppDatabase, tools: ClaudeTools, transport: MessagesTransport, clock: Clock, timeZone: TimeZone, model: String,
         actions: AssistantActions? = nil) {
        self.actions = actions
        self.db = db
        self.tools = tools
        self.transport = transport
        self.clock = clock
        self.timeZone = timeZone
        self.model = model
    }

    /// The request body for a conversation so far (also inspected by the privacy test).
    func requestBody(_ messages: [[String: Any]]) -> (body: [String: Any], betas: [String]) {
        // Volatile context (today's date) goes in the first user turn, not the system prompt,
        // so the system prompt and tools stay cacheable.
        var body: [String: Any] = [
            "model": model,
            "max_tokens": Self.maxTokens,
            "system": [["type": "text", "text": Self.systemPrompt, "cache_control": ["type": "ephemeral"]]],
            "tools": ClaudeTools.definitions,
            "tool_choice": ["type": "auto"],
            "messages": messages,
        ]
        var betas: [String] = []
        if Self.fallbackModels.contains(model) {
            body["fallbacks"] = "default"
            betas.append(Self.fallbackBeta)
        }
        return (body, betas)
    }

    static func localDate(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd (EEEE) HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }

    func ask(_ question: String) async -> Answer {
        let now = clock.now
        var messages: [[String: Any]] = [["role": "user", "content": [
            ["type": "text", "text": "Now: \(Self.localDate(now, timeZone)) (\(timeZone.identifier))."],
            ["type": "text", "text": question],
        ]]]
        var answer = Answer(text: "")
        var calls: [[String: Any]] = []
        var toolChars = 0
        var rounds = 0
        do {
            while true {
                let (body, betas) = requestBody(messages)
                let raw = try await transport.send(try JSONSerialization.data(withJSONObject: body), betas: betas)
                let resp = (try JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
                let usage = resp["usage"] as? [String: Any] ?? [:]
                answer.inputTokens += (usage["input_tokens"] as? Int ?? 0) + (usage["cache_read_input_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                answer.outputTokens += usage["output_tokens"] as? Int ?? 0
                let content = resp["content"] as? [[String: Any]] ?? []
                let stop = resp["stop_reason"] as? String ?? ""
                let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                    .joined(separator: "\n")
                if stop == "refusal" {
                    answer.text = text.isEmpty ? "Claude declined to answer this question." : text
                    answer.error = "refusal"
                    break
                }
                let uses = content.filter { $0["type"] as? String == "tool_use" }
                guard stop == "tool_use", !uses.isEmpty else {
                    answer.text = text
                    if stop == "max_tokens" { answer.text += "\n\n[answer cut off at the length limit]" }
                    break
                }
                rounds += 1
                // Append the assistant turn unchanged (incl. thinking blocks), then all tool results in one user turn.
                messages.append(["role": "assistant", "content": content])
                var results: [[String: Any]] = []
                for u in uses {
                    let id = u["id"] as? String ?? "", name = u["name"] as? String ?? ""
                    let input = u["input"] as? [String: Any] ?? [:]
                    var out: String, isError = false
                    if rounds > Self.maxToolRounds {
                        out = "Tool budget reached (\(Self.maxToolRounds) rounds). Answer with the data you already have."
                        isError = true
                    } else if toolChars >= Self.maxToolChars {
                        out = "Tool output budget for this question is used up. Answer with the data you already have."
                        isError = true
                    } else {
                        do {
                            let json = try JSONSerialization.data(withJSONObject: input)
                            if let actions, let r = try await actions.run(name: name, inputJSON: json) {
                                out = r.output
                                if let id = r.reportID { answer.reportIDs.append(id) }
                                if let p = r.proposedLabels { answer.proposedLabels = p }
                            } else if ["create_report", "propose_report_labels"].contains(name) {
                                throw ClaudeTools.ToolError(description: "\(name) is not available here")
                            } else {
                                out = try tools.run(name, input)
                            }
                        } catch {
                            out = "Error: \(error)"
                            isError = true
                        }
                        let room = Self.maxToolChars - toolChars
                        if out.count > room { out = String(out.prefix(room)) + "…[truncated: question's tool budget reached]" }
                        toolChars += out.count
                    }
                    answer.toolCalls.append(name)
                    answer.calls.append(ToolCall(name: name, input: input.mapValues { v in
                        (v as? [Any]).map { $0.map { "\($0)" }.joined(separator: "\n") } ?? "\(v)"
                    }))
                    calls.append(["name": name, "input": input, "output_chars": out.count, "error": isError])
                    var r: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": out]
                    if isError { r["is_error"] = true }
                    results.append(r)
                }
                messages.append(["role": "user", "content": results])
                if rounds > Self.maxToolRounds + 1 {
                    // The model ignored the budget notice; stop without another request.
                    answer.text = text.isEmpty ? "Stopped: too many tool calls." : text
                    answer.error = "tool_round_limit"
                    break
                }
            }
        } catch {
            answer.error = "\(error)"
            answer.text = "Couldn't reach Claude: \(error)"
        }
        answer.logID = Self.log(db: db, model: model, question: question, calls: calls, answer: answer, at: now)
        return answer
    }

    static func log(db: AppDatabase, model: String, question: String, calls: [[String: Any]], answer: Answer, at: Date) -> Int64? {
        let callsJSON = (try? JSONSerialization.data(withJSONObject: calls, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
        return try? db.writer.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO ai_log (ts, question, model, tool_calls_json, response_text, input_tokens, output_tokens, error)
                VALUES (?,?,?,?,?,?,?,?)
                """, arguments: [at.timeIntervalSince1970, question, model, callsJSON, answer.text,
                                 answer.inputTokens, answer.outputTokens, answer.error])
            return db.lastInsertedRowID
        }
    }
}
