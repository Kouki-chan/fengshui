import GRDB
import SwiftUI
import UIKit

/// App-wide UI state that must outlive any one tab (DECISIONS D-23): the selected tab, the Ask
/// conversation (so a question keeps running while the user browses other tabs), the inbox
/// unread count (one database observation for every tab's bell) and whether an API key is set
/// (a Keychain lookup, so it's cached instead of being read on every redraw).
@MainActor
@Observable
final class UIState {
    enum TabID: Hashable { case today, data, reports, ask, settings }

    let ask: AskSession
    let data: DataModel
    var tab: TabID = .today { didSet { ask.isVisible = tab == .ask } }
    private(set) var unread = 0
    private(set) var hasKey = false
    private let env: AppEnvironment
    private var inboxObservation: Task<Void, Never>?

    init(env: AppEnvironment) {
        self.env = env
        ask = AskSession(env: env)
        data = DataModel(env: env)
        refreshKey()
    }

    func refreshKey() {
        hasKey = env.secrets.get(SecretKey.anthropicKey).map { !$0.isEmpty } ?? false
    }

    /// Starts the single unread-count observation (idempotent).
    func observeInbox() {
        guard inboxObservation == nil else { return }
        let writer = env.db.writer
        inboxObservation = Task { [weak self] in
            let obs = ValueObservation.tracking { try InboxStore.unread($0) }.removeDuplicates()
            do {
                for try await n in obs.values(in: writer) { self?.unread = n }
            } catch {}
        }
    }
}

/// The Ask conversation. Questions are queued and answered one at a time (the Managed Agent
/// chat is a single session) by a task owned here rather than by the view, so switching tabs
/// never cancels or loses an answer. While the app is in the background, iOS's extra
/// background time lets an answer that's already streaming finish; if it lands while the user
/// is elsewhere, the Ask tab gets a badge, or a notification when the app isn't open.
@MainActor
@Observable
final class AskSession {
    struct Turn: Identifiable, Equatable {
        enum State: Equatable { case queued, running, done, stopped }
        let id = UUID()
        let question: String
        var answer: ClaudeAssistant.Answer?
        var report: ReportRecord?
        var state = State.queued
    }

    static let noKeyAnswer = "Add your Anthropic API key in Settings → Claude first."

    private(set) var turns: [Turn] = []
    /// Answers that arrived while the Ask tab wasn't on screen (shown as the tab's badge).
    private(set) var unseen = 0
    var isVisible = false { didSet { if isVisible { unseen = 0 } } }
    var isWorking: Bool { worker != nil }

    private let env: AppEnvironment
    private let makeAssistant: @MainActor () -> (any Assistant)?
    private var worker: Task<Void, Never>?

    /// `assistant`: tests pass a fake; the app uses the configured backend (Managed Agent or API).
    init(env: AppEnvironment, assistant: (@MainActor () -> (any Assistant)?)? = nil) {
        self.env = env
        makeAssistant = assistant ?? { env.assistant(chat: true) }
    }

    func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        turns.append(Turn(question: q))
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drain()
            self?.worker = nil
        }
    }

    /// Stops the running answer and drops the queued ones.
    func stop() { worker?.cancel() }

    func clear() {
        guard worker == nil else { return }
        turns.removeAll()
    }

    /// Waits until every queued question has been answered or stopped (tests).
    func idle() async {
        while let w = worker { await w.value }
    }

    private func drain() async {
        while let turn = turns.first(where: { $0.state == .queued }) {
            if Task.isCancelled { break }
            update(turn.id) { $0.state = .running }
            let background = BackgroundTime(name: "HealthBot answer")
            let assistant = makeAssistant()
            let answer = await assistant?.ask(turn.question) ?? ClaudeAssistant.Answer(text: Self.noKeyAnswer)
            let stopped = Task.isCancelled
            update(turn.id) {
                $0.answer = answer
                $0.state = stopped ? .stopped : .done
            }
            if !stopped, assistant != nil {
                // Every question also becomes a report (unless the answer made one already).
                var report = answer.reportIDs.last.flatMap(env.reports.record)
                if report == nil { report = await env.reports.questionReport(question: turn.question, answer: answer) }
                update(turn.id) { [report] in $0.report = report }
            }
            if !isVisible { unseen += 1 }
            if !stopped, UIApplication.shared.applicationState != .active { await notify(turn.question, answer) }
            background.end()
        }
        for i in turns.indices where turns[i].state == .queued { turns[i].state = .stopped }
    }

    private func update(_ id: UUID, _ change: (inout Turn) -> Void) {
        if let i = turns.firstIndex(where: { $0.id == id }) { change(&turns[i]) }
    }

    private func notify(_ question: String, _ answer: ClaudeAssistant.Answer) async {
        let preview = answer.text.count > 160 ? String(answer.text.prefix(157)) + "…" : answer.text
        try? await env.notifications.add(LocalNotification(identifier: "question-answer-\(UUID().uuidString)",
                                                           title: "HealthBot answered: \(question)", body: preview),
                                         timeZone: env.timeZone)
    }
}

/// Extra running time from iOS while the app is in the background (public UIApplication API,
/// ended as soon as the work finishes or iOS asks for it back).
@MainActor
final class BackgroundTime {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
