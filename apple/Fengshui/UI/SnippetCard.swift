import GRDB
import SwiftUI

/// Today's HealthBot snippet (DECISIONS D-24): one short insight about the user's data, or a
/// question that prompts them to reflect. HealthBot always has a few built on the iPhone from
/// processed data and the profile's goals; with an API key, Claude (the user's Managed Agent when
/// configured) also writes one a day (cached, so it costs one question a day plus any manual refresh).
struct Snippet: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case insight, question }

    var id: String
    var kind: Kind
    var text: String
    /// What tapping the snippet asks HealthBot (insights) or the reply it starts (questions).
    var ask: String?
    var systemImage = "sparkles"
    var byClaude = false
}

@MainActor
@Observable
final class SnippetModel {
    struct Cached: Codable, Sendable {
        var date: String
        var snippet: Snippet
    }

    static let cacheKey = "today_snippet"

    private(set) var snippets: [Snippet] = []
    private(set) var index = 0
    private(set) var generating = false
    private(set) var error: String?
    var current: Snippet? { snippets.isEmpty ? nil : snippets[index % snippets.count] }

    private let env: AppEnvironment
    private var worker: Task<Void, Never>?

    init(env: AppEnvironment) { self.env = env }

    /// Rebuilds the on-device snippets and, once a day, asks Claude for one (in the background,
    /// owned here so switching tabs doesn't cancel it).
    func refresh() async {
        let env = env
        let profile = UserProfile.load(env.db)
        let today = Self.day(env.clock.now, env.timeZone)
        let built = (try? await env.db.writer.read { db in
            try Self.local(db, now: env.clock.now, timeZone: env.timeZone, profile: profile)
        }) ?? []
        let cached = ((try? env.db.preference(Self.cacheKey, as: Cached.self)) ?? nil).flatMap { $0.date == today ? $0.snippet : nil }
        let keepID = current?.id
        let next = (cached.map { [$0] } ?? []) + built
        if next != snippets {
            snippets = next
            index = keepID.flatMap { id in next.firstIndex { $0.id == id } } ?? 0
        }
        if cached == nil { generate() }
    }

    /// Shows the next snippet.
    func next() {
        guard snippets.count > 1 else { return }
        index = (index + 1) % snippets.count
    }

    /// Asks Claude for a new snippet (no-op without an API key or while one is being written).
    func generate() {
        // Your Managed Agent when one is set up in Settings → Agent (its own session, so the Ask
        // conversation isn't touched), else the direct API.
        guard worker == nil, !env.isTestMode, let assistant = env.assistant() else { return }
        generating = true
        error = nil
        worker = Task { [weak self, env] in
            let answer = await assistant.ask(Self.prompt)
            guard let self else { return }
            if let s = Self.parse(answer.text), answer.error == nil {
                try? env.db.setPreference(Self.cacheKey, Cached(date: Self.day(env.clock.now, env.timeZone), snippet: s),
                                          now: env.clock.now)
                snippets.removeAll { $0.byClaude }
                snippets.insert(s, at: 0)
                index = 0
            } else {
                error = answer.error ?? "HealthBot couldn't write a snippet this time."
            }
            generating = false
            worker = nil
        }
    }

    static let prompt = """
        Write today's snippet for the top of my HealthBot Today screen. Look at a little of my recent data \
        (last night's sleep, today's activity so far, and how my vitals compare with my usual) and choose the single \
        most useful thing for me right now: either an insight about my data, or a short question that prompts me to \
        reflect on something you noticed. Reply with exactly these three lines and nothing else:
        TYPE: insight or question
        TEXT: at most two short sentences, warm and specific, with a number from my data
        ASK: a follow-up question I could ask you about it
        """

    nonisolated static func parse(_ text: String) -> Snippet? {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[parts[0].trimmingCharacters(in: .whitespaces).uppercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard let body = fields["TEXT"], !body.isEmpty else { return nil }
        let kind: Snippet.Kind = fields["TYPE"]?.lowercased().contains("question") == true ? .question : .insight
        return Snippet(id: "claude", kind: kind, text: body, ask: fields["ASK"].flatMap { $0.isEmpty ? nil : $0 },
                       systemImage: kind == .question ? "bubble.left.and.text.bubble.right.fill" : "sparkles",
                       byClaude: true)
    }

    nonisolated static func day(_ d: Date, _ tz: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Snippets built on the iPhone from processed data, most useful first.
    nonisolated static func local(_ db: Database, now: Date, timeZone: TimeZone, profile: UserProfile) throws -> [Snippet] {
        let data = try DataSnapshot.fetch(db, now: now, timeZone: timeZone)
        let rows = try TodayView.fetch(db, now: now, timeZone: timeZone)
        let plan = rows.plan.map(TodayView.obj) ?? [:]
        let day = rows.day.map(TodayView.obj) ?? [:]
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let hour = Double(cal.component(.hour, from: now)) + Double(cal.component(.minute, from: now)) / 60
        var out: [Snippet] = []

        // Last night's sleep against the profile's goal.
        let slept = data.sleep.asleep / 60
        let goal = profile.sleepGoalHours * 60
        if slept > 0 {
            let gap = goal - slept
            if gap >= 45 {
                out.append(Snippet(id: "sleep.short", kind: .insight,
                                   text: "You slept \(hm(slept)) last night, \(hm(gap)) under your \(profile.sleepGoalHours.formatted()) h goal.",
                                   ask: "Why might I have slept less last night?", systemImage: "bed.double.fill"))
                out.append(Snippet(id: "sleep.why", kind: .question, text: "Did anything keep you up last night?",
                                   ask: "About last night's short sleep: ", systemImage: "moon.zzz.fill"))
            } else if gap <= 0 {
                let deep = data.sleep.deep > 0 ? " with \(hm(data.sleep.deep / 60)) of deep sleep" : ""
                out.append(Snippet(id: "sleep.good", kind: .insight,
                                   text: "You met your sleep goal: \(hm(slept)) last night\(deep).",
                                   ask: "What helped me sleep well last night?", systemImage: "bed.double.fill"))
            }
        }

        // Sleep debt and tonight's plan.
        if let debt = plan["sleep_debt_min"] as? Int, debt >= 60, let start = plan["wind_down_start"] as? String {
            out.append(Snippet(id: "sleep.debt", kind: .insight,
                               text: "You're carrying about \(hm(Double(debt))) of sleep debt. Winding down at \(start) tonight helps you catch up.",
                               ask: "How can I pay back my sleep debt this week?", systemImage: "moon.stars.fill"))
        }

        // Steps against the goal, paced over a 7:00–22:00 day.
        let steps = (day["steps"] as? Int) ?? data.totals.first { $0.label == "step_count" }.map { Int($0.value) }
        if let steps, hour >= 10 {
            let target = Double(profile.stepGoal)
            let expected = target * min(1, max(0, (hour - 7) / 15))
            if Double(steps) >= target {
                out.append(Snippet(id: "steps.done", kind: .insight,
                                   text: "Goal reached: \(steps.formatted()) steps today, past your \(profile.stepGoal.formatted()).",
                                   ask: "How does today's activity compare with my usual week?", systemImage: "figure.walk"))
            } else if Double(steps) < expected * 0.7 {
                let left = profile.stepGoal - steps
                out.append(Snippet(id: "steps.behind", kind: .insight,
                                   text: "\(steps.formatted()) steps so far, \(left.formatted()) to go. A 20-minute walk adds about 2,000.",
                                   ask: "When am I usually most active during the day?", systemImage: "figure.walk"))
            }
        }

        // A long sitting stretch today.
        if let sitting = day["longest_sedentary_min"] as? Int, sitting >= 90 {
            out.append(Snippet(id: "sitting", kind: .insight,
                               text: "Your longest sitting stretch today was \(hm(Double(sitting))). Short breaks every hour help.",
                               ask: "When do I tend to sit the longest?", systemImage: "chair.lounge.fill"))
        }

        // Resting heart rate and HRV against the previous two weeks.
        for (label, name, unit, higherIsBad) in [("resting_heart_rate", "Resting heart rate", "bpm", true),
                                                ("heart_rate_variability_sdnn", "Heart rate variability", "ms", false)] {
            guard let r = data.vitals.first(where: { $0.label == label }), r.series.count >= 5,
                  let last = r.series.last?.value else { continue }
            let before = r.series.dropLast().map(\.value)
            let base = before.reduce(0, +) / Double(before.count)
            let diff = last - base
            let threshold = label == "resting_heart_rate" ? 4.0 : base * 0.15
            guard abs(diff) >= threshold else { continue }
            let direction = diff > 0 ? "above" : "below"
            let worse = (diff > 0) == higherIsBad
            out.append(Snippet(id: "vital.\(label)", kind: .insight,
                               text: "\(name) is \(Int(abs(diff).rounded())) \(unit) \(direction) your two-week average"
                                   + (worse ? ". Rest, stress or a late meal can all do this." : ", a good sign of recovery."),
                               ask: "Why might my \(name.lowercased()) be \(direction) usual lately?",
                               systemImage: label == "resting_heart_rate" ? "heart.circle.fill" : "waveform.path.ecg"))
        }

        // Questions that invite the user in.
        if profile.goals.isEmpty {
            out.append(Snippet(id: "profile.goals", kind: .question,
                               text: "What would you like to focus on? Add goals in your profile and I'll tailor these notes.",
                               ask: nil, systemImage: "target"))
        } else if let goal = profile.goals.first {
            out.append(Snippet(id: "goal.checkin", kind: .question, text: "How is \"\(goal.lowercased())\" going this week?",
                               ask: "About my goal to \(goal.lowercased()): ", systemImage: "target"))
        }
        out.append(Snippet(id: "checkin", kind: .question,
                           text: hour < 12 ? "How are you feeling this morning?" : hour < 18 ? "How's your energy this afternoon?"
                               : "How was your day?",
                           ask: "How I'm feeling today: ", systemImage: "face.smiling"))
        return out
    }

    nonisolated static func hm(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }
}

/// The snippet card at the top of Today.
struct SnippetCard: View {
    let ui: UIState
    var openProfile: () -> Void
    @Environment(\.theme) private var theme

    private var model: SnippetModel { ui.snippets }

    var body: some View {
        if let s = model.current {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    HealthBotLogo(size: 26)
                    Text(s.kind == .question ? "A question for you" : "Insight")
                        .font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundStyle(theme.highlight)
                    Spacer()
                    if model.generating {
                        ProgressView().controlSize(.small).accessibilityLabel("HealthBot is writing a snippet")
                    }
                    if model.snippets.count > 1 {
                        Button { withAnimation(.snappy) { model.next() } } label: {
                            Image(systemName: "arrow.trianglehead.2.clockwise").font(.footnote.weight(.semibold))
                                .frame(width: 30, height: 30)
                                .background(theme.tint.opacity(0.12), in: .circle)
                        }
                        .buttonStyle(.plain).foregroundStyle(theme.tint)
                        .accessibilityLabel("Next snippet")
                        .accessibilityIdentifier("today.snippet.next")
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: s.systemImage).font(.title3).foregroundStyle(theme.tint).frame(width: 26)
                    Text(s.text).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("today.snippet.text")
                }
                .id(s.id)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
                action(s)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface, in: .rect(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(theme.highlight.opacity(0.25)))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
            .contextMenu {
                Button("Write a new one with the agent", systemImage: "sparkles") { model.generate() }.disabled(!ui.hasKey)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("today.snippet")
        }
    }

    @ViewBuilder private func action(_ s: Snippet) -> some View {
        let label: (String, String)? = switch (s.kind, s.ask) {
        case (.insight, .some): ("Ask HealthBot about this", "bubble.left.and.text.bubble.right")
        case (.question, .some): ("Reply", "arrowshape.turn.up.left")
        case (_, .none) where s.id == "profile.goals": ("Set goals", "target")
        default: nil
        }
        if let label {
            Button {
                if s.id == "profile.goals" { openProfile(); return }
                guard let ask = s.ask else { return }
                if s.kind == .insight { ui.ask.send(ask) } else { ui.ask.prefill = ask }
                ui.tab = .ask
            } label: {
                Label(label.0, systemImage: label.1).font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(theme.tint.opacity(0.12), in: .capsule)
            }
            .buttonStyle(.plain).foregroundStyle(theme.tint)
            .accessibilityIdentifier("today.snippet.action")
        }
    }
}
