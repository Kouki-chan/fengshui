import GRDB
import SwiftUI

/// Spec §15 Ask: preset questions + free-form chat. Settings → Claude holds the key and model.
/// The conversation lives in `AskSession` (UIState), not here: a question keeps running while
/// the user switches tabs, and the Ask tab shows a badge when its answer arrives.
struct AskView: View {
    let env: AppEnvironment
    let ui: UIState
    @Environment(\.theme) private var theme
    @State private var questions: [AIQuestion] = []
    @State private var draft = ""
    @State private var managing = false
    @FocusState private var composing: Bool

    private var session: AskSession { ui.ask }
    private var presets: [AIQuestion] { questions.filter(\.enabled) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if session.turns.isEmpty { welcome }
                    ForEach(session.turns) { t in
                        AskTurnView(env: env, turn: t).id(t.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.turns) { withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .themedBackground()
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle("Ask HealthBot")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Manage questions", systemImage: "list.bullet") { managing = true }
                    Button("Clear conversation", systemImage: "trash", role: .destructive) { session.clear() }
                        .disabled(session.turns.isEmpty || session.isWorking)
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Ask options")
            }
        }
        .navigationDestination(isPresented: $managing) { QuestionsEditor(env: env) }
        .task { questions = (try? env.questions.all()) ?? [] }
        // Leaving the tab must not leave the keyboard up over another screen.
        .onDisappear { composing = false }
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 10) {
                HealthBotLogo(size: 76)
                Text("Hi, I'm HealthBot").font(.title2.weight(.bold))
                Text("Ask about your sleep, activity and vitals. I only see processed data from your iPhone, never raw watch data.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.top, 12)
            if !ui.hasKey {
                NavigationLink { ClaudeSettingsView(env: env) } label: {
                    Card {
                        HStack(spacing: 12) {
                            IconBadge(systemImage: "key.fill", tint: theme.highlight)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Add your Anthropic API key").font(.subheadline.weight(.semibold))
                                Text("Stored only in this iPhone's Keychain.").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            if !presets.isEmpty {
                CardSection(title: "Try asking", systemImage: "sparkles", tint: theme.highlight) {
                    VStack(spacing: 8) {
                        ForEach(presets) { q in
                            Button { send(q.text) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(q.text).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                            .multilineTextAlignment(.leading)
                                        if let sch = q.schedule {
                                            Label("Scheduled \(sch)", systemImage: "clock").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.circle.fill").font(.title3).foregroundStyle(theme.tint)
                                }
                                .padding(12)
                                .background(theme.surface, in: .rect(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(q.text)
                        }
                    }
                }
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Menu {
                ForEach(presets) { q in Button(q.text) { send(q.text) } }
                Divider()
                Button("Manage questions", systemImage: "list.bullet") { managing = true }
            } label: {
                Image(systemName: "sparkles").font(.title3).foregroundStyle(theme.highlight).frame(width: 38, height: 38)
            }
            .accessibilityLabel("Preset questions")
            TextField("Ask about your sleep, activity…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($composing)
                .submitLabel(.send)
                .padding(.vertical, 9)
                .accessibilityIdentifier("ask.input")
                // Return sends (a vertical field would otherwise insert a new line).
                .onChange(of: draft) { _, new in
                    if new.hasSuffix("\n") { draft = String(new.dropLast()); send(draft) }
                }
            if session.isWorking && draft.isEmpty {
                Button { session.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 32)).foregroundStyle(theme.tint)
                }
                .accessibilityLabel("Stop answering")
                .accessibilityIdentifier("ask.stop")
            } else {
                Button { send(draft) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : theme.tint)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Ask")
                .accessibilityIdentifier("ask.send")
            }
        }
        .padding(.leading, 4).padding(.trailing, 4).padding(.vertical, 3)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        draft = ""
        composing = false
        session.send(q)
    }
}

/// One question and its answer as chat bubbles.
struct AskTurnView: View {
    let env: AppEnvironment
    let turn: AskSession.Turn
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 48)
                Text(turn.question)
                    .font(.body).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(theme.tint, in: .rect(cornerRadius: 20, style: .continuous))
                    .textSelection(.enabled)
            }
            HStack(alignment: .top, spacing: 8) {
                HealthBotLogo(size: 30)
                VStack(alignment: .leading, spacing: 8) { reply }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(theme.surface, in: .rect(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
                Spacer(minLength: 24)
            }
        }
    }

    @ViewBuilder private var reply: some View {
        switch (turn.state, turn.answer) {
        case (.queued, _):
            Label("Waiting for the previous question…", systemImage: "hourglass").font(.subheadline).foregroundStyle(.secondary)
        case (.running, _):
            TypingIndicator()
            Text("Looking at your data. You can switch tabs; the answer will wait here.")
                .font(.caption).foregroundStyle(.secondary)
        case (_, let a?):
            Text(LocalizedStringKey(a.text)).textSelection(.enabled)
                .accessibilityIdentifier("ask.answer")
            if turn.state == .stopped { Label("Stopped", systemImage: "stop.circle").font(.caption).foregroundStyle(.secondary) }
            if !a.toolCalls.isEmpty || a.inputTokens + a.outputTokens > 0 || a.error != nil {
                Text("\(a.toolCalls.count) tool calls · \(a.inputTokens + a.outputTokens) tokens\(a.error.map { " · \($0)" } ?? "")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let by = a.answeredBy {
                Label("via \(by)", systemImage: by.hasPrefix("Managed") ? "person.badge.shield.checkmark" : "cloud")
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("ask.answeredBy")
            }
            if let r = turn.report {
                NavigationLink { ReportDetailView(env: env, report: r) } label: {
                    Chip(text: "Report saved · \(r.pages) p", systemImage: "doc.richtext", foreground: theme.tint,
                         background: theme.tint.opacity(0.12))
                }
                .accessibilityIdentifier("ask.report")
            }
        case (_, nil):
            Label("Stopped", systemImage: "stop.circle").font(.subheadline).foregroundStyle(.secondary)
        }
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
        .themedList()
        .keyboardDoneButton()
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
    @Environment(UIState.self) private var ui: UIState?
    @State private var key = ""
    @State private var model = ClaudeAssistant.defaultModel
    @State private var managed = ManagedAgentConfig()
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
                    ui?.refreshKey()
                    hideKeyboard()
                }
            } footer: { Text("The key is stored only in this iPhone's Keychain.") }
            Section {
                Toggle("Use my Managed Agent", isOn: $managed.enabled).accessibilityIdentifier("claude.managed")
                TextField("Agent ID (agent_…)", text: $managed.agentID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(.callout.monospaced())
                TextField("Chat session ID (sesn_…)", text: $managed.chatSessionID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(.callout.monospaced())
                if !managed.environmentID.isEmpty {
                    LabeledContent("Environment", value: managed.environmentID).font(.caption)
                }
                Button("Save agent settings") {
                    managed.agentID = managed.agentID.trimmingCharacters(in: .whitespaces)
                    managed.chatSessionID = managed.chatSessionID.trimmingCharacters(in: .whitespaces)
                    managed.save(env.db)
                }
            } header: { Text("Managed Agent") } footer: {
                Text(managed.isUsable
                     ? "Questions go to your agent. The Ask chat continues in the session above; report steps get their own sessions. "
                       + "HealthBot's data tools are added to those sessions only (your agent isn't changed) and run on this iPhone."
                     : "Off: questions use the Claude API directly with the model above.")
            }
            Section { NavigationLink("Conversation log") { AILogView(env: env) } }
        }
        .themedList()
        .keyboardDoneButton()
        .navigationTitle("Claude")
        .task {
            key = env.secrets.get(SecretKey.anthropicKey) ?? ""
            model = env.claudeModel
            managed = ManagedAgentConfig.load(env.db)
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
        .themedList()
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
