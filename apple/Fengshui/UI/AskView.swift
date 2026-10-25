import GRDB
import SwiftUI

/// Spec §15 Ask: preset questions + free-form chat. Settings → Claude holds the key and model.
struct AskView: View {
    let env: AppEnvironment
    @State private var questions: [AIQuestion] = []
    @State private var draft = ""
    @State private var turns: [(q: String, a: ClaudeAssistant.Answer?)] = []
    @State private var busy = false

    var body: some View {
        List {
            if env.secrets.get(SecretKey.anthropicKey) == nil {
                Section {
                    NavigationLink("Add your Anthropic API key") { ClaudeSettingsView(env: env) }
                } footer: { Text("Claude only receives processed data and inferences through tools — never raw watch data.") }
            }
            Section("Questions") {
                ForEach(questions.filter(\.enabled)) { q in
                    Button { Task { await ask(q.text) } } label: {
                        VStack(alignment: .leading) {
                            Text(q.text)
                            if let s = q.schedule { Text("Scheduled: \(s)").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    .disabled(busy)
                }
                NavigationLink("Manage questions") { QuestionsEditor(env: env) }
            }
            ForEach(Array(turns.enumerated()), id: \.offset) { _, t in
                Section {
                    Text(t.q).bold()
                    if let a = t.a {
                        Text(LocalizedStringKey(a.text)).textSelection(.enabled)
                            .accessibilityIdentifier("ask.answer")
                        Text("\(a.toolCalls.count) tool calls · \(a.inputTokens + a.outputTokens) tokens\(a.error.map { " · \($0)" } ?? "")")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                TextField("Ask about your sleep, activity…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ask.input")
                Button("Ask") { let q = draft; draft = ""; Task { await ask(q) } }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    .accessibilityIdentifier("ask.send")
            }
            .padding()
            .background(.bar)
        }
        .navigationTitle("Ask")
        .task { questions = (try? env.questions.all()) ?? [] }
    }

    private func ask(_ q: String) async {
        guard let a = env.assistant() else {
            turns.append((q, ClaudeAssistant.Answer(text: "Add your Anthropic API key in Settings → Claude first.")))
            return
        }
        busy = true
        turns.append((q, nil))
        let ans = await a.ask(q)
        turns[turns.count - 1].a = ans
        busy = false
    }
}

struct QuestionsEditor: View {
    let env: AppEnvironment
    @State private var questions: [AIQuestion] = []
    @State private var newText = ""
    @State private var newSchedule = ""
    @State private var error: String?

    var body: some View {
        Form {
            ForEach($questions) { $q in
                VStack(alignment: .leading) {
                    TextField("Question", text: $q.text).disabled(q.owner == "dev")
                    TextField("Schedule (daily:21:00 or weekly:sun:19:00)",
                              text: Binding(get: { q.schedule ?? "" }, set: { q.schedule = $0.isEmpty ? nil : $0 }))
                        .font(.caption).textInputAutocapitalization(.never)
                    Toggle("Enabled", isOn: $q.enabled)
                }
                .onChange(of: q) { _, new in save(new) }
            }
            .onDelete { idx in
                for i in idx where questions[i].owner == "user" { try? env.questions.delete(questions[i].id) }
                reload()
            }
            Section("New question") {
                TextField("Question", text: $newText)
                TextField("Schedule (optional)", text: $newSchedule).textInputAutocapitalization(.never)
                Button("Add") {
                    do {
                        try env.questions.add(newText, schedule: newSchedule.isEmpty ? nil : newSchedule)
                        newText = ""; newSchedule = ""; error = nil
                    } catch { self.error = "Schedule must look like daily:21:00 or weekly:sun:19:00" }
                    reload()
                }
                .disabled(newText.isEmpty)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        }
        .navigationTitle("Questions")
        .task { reload() }
    }

    private func save(_ q: AIQuestion) {
        do { try env.questions.update(q); self.error = nil } catch { self.error = "Invalid schedule for “\(q.text)”" }
    }

    private func reload() { questions = (try? env.questions.all()) ?? [] }
}

/// Settings → Claude: API key (Keychain only), model, and the ai_log viewer.
struct ClaudeSettingsView: View {
    let env: AppEnvironment
    @State private var key = ""
    @State private var model = ClaudeAssistant.defaultModel
    static let models = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"]

    var body: some View {
        Form {
            Section {
                SecureField("sk-ant-…", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("claude.key")
                Picker("Model", selection: $model) { ForEach(Self.models, id: \.self) { Text($0) } }
                Button("Save") {
                    env.secrets.set(SecretKey.anthropicKey, key.trimmingCharacters(in: .whitespacesAndNewlines))
                    try? env.db.setPreference(ClaudeAssistant.modelKey, model, now: env.clock.now)
                }
            } footer: { Text("The key is stored only in this iPhone's Keychain.") }
            Section { NavigationLink("Conversation log") { AILogView(env: env) } }
        }
        .navigationTitle("Claude")
        .task {
            key = env.secrets.get(SecretKey.anthropicKey) ?? ""
            model = env.claudeModel
        }
    }
}

struct AILogView: View {
    struct Entry: Sendable { var ts: Double; var question: String; var model: String; var tools: String; var tokens: Int; var error: String?; var response: String }
    let env: AppEnvironment
    @State private var rows: [Entry] = []

    var body: some View {
        List(Array(rows.enumerated()), id: \.offset) { _, r in
            VStack(alignment: .leading, spacing: 4) {
                Text(r.question).font(.subheadline.bold())
                Text("\(Date(timeIntervalSince1970: r.ts).formatted(date: .abbreviated, time: .shortened)) · \(r.model) · \(r.tokens) tokens")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(r.tools).font(.caption2.monospaced()).lineLimit(3)
                if let e = r.error { Text(e).font(.caption2).foregroundStyle(.red) }
                Text(r.response).font(.caption).lineLimit(6)
            }
        }
        .navigationTitle("Claude log")
        .task {
            rows = (try? await env.db.writer.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM ai_log ORDER BY id DESC LIMIT 100").map {
                    Entry(ts: $0["ts"], question: $0["question"], model: $0["model"], tools: ($0["tool_calls_json"] as String?) ?? "",
                          tokens: (($0["input_tokens"] as Int?) ?? 0) + (($0["output_tokens"] as Int?) ?? 0),
                          error: $0["error"], response: ($0["response_text"] as String?) ?? "")
                }
            }) ?? []
        }
    }
}
