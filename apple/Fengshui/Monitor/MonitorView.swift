import SwiftUI

/// Settings → Health monitor (DECISIONS D-19): the user chooses how often the server checks
/// and for how long; alerts land in the inbox and as notifications.
struct MonitorView: View {
    let env: AppEnvironment
    @State private var interval = 5.0
    @State private var duration = 4.0
    @State private var session: MonitorSession?
    @State private var serverInfo: [String: Any]?
    @State private var error: String?
    @State private var busy = false

    static let intervals: [Double] = [1, 2, 5, 10, 15, 30, 60]
    static let durations: [Double] = [0.25, 0.5, 1, 2, 4, 8, 12, 24]

    var body: some View {
        Form {
            if env.server.baseURL == nil {
                Section {
                    NavigationLink("Connect to your Mac server first") { ServerSettingsView(env: env) }
                } footer: { Text("The monitoring agent runs on the Fengshui server on your Mac.") }
            }
            if let s = session, s.isActive {
                activeSection(s)
            } else {
                Section {
                    Picker("Check every", selection: $interval) {
                        ForEach(Self.intervals, id: \.self) { Text("\(Int($0)) min") }
                    }
                    .accessibilityIdentifier("monitor.interval")
                    Picker("Monitor for", selection: $duration) {
                        ForEach(Self.durations, id: \.self) { Text(Self.durationText($0)) }
                    }
                    .accessibilityIdentifier("monitor.duration")
                    Button(busy ? "Starting…" : "Start monitoring") { Task { await start() } }
                        .disabled(busy || env.server.baseURL == nil)
                        .accessibilityIdentifier("monitor.start")
                } header: { Text("New session") } footer: {
                    Text("At each check the server compares your latest heart rate, blood oxygen, breathing rate and HRV "
                         + "with fixed limits and your own 30-day baseline. Only when something looks off does Claude look at the "
                         + "context and decide whether to notify you. Very low oxygen and a very high resting heart rate always notify.")
                }
                if let s = session { lastSection(s) }
            }
            Section("Delivery") {
                LabeledContent("Server agent", value: agentText)
                LabeledContent("Apple push", value: pushText)
                Text(pushExplanation).font(.caption).foregroundStyle(.secondary)
            }
            if let error { Section { Text(error).foregroundStyle(.red).font(.caption) } }
            Section {
                Text("Not a medical device and not for emergencies. If you feel unwell, contact a clinician or call emergency services.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Health monitor")
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func activeSection(_ s: MonitorSession) -> some View {
        Section {
            LabeledContent("Checks every", value: "\(Int(s.intervalS / 60)) min")
            LabeledContent("Ends", value: Date(timeIntervalSince1970: s.endTs).formatted(date: .omitted, time: .shortened))
            LabeledContent("Checks with data", value: "\(s.stats.intervalsWithData) of \(s.stats.intervals) (\(Int(s.stats.coverage * 100)) %)")
                .accessibilityIdentifier("monitor.coverage")
            LabeledContent("Last reading", value: s.stats.lastReadingTs.map { ago($0, now: env.clock.now) } ?? "none yet")
            LabeledContent("Alerts", value: "\(s.stats.alerts)")
            Button("Send readings now") { Task { await sendNow() } }.disabled(busy)
            Button("Stop monitoring", role: .destructive) { Task { await stop() } }.disabled(busy)
                .accessibilityIdentifier("monitor.stop")
        } header: { Text("Monitoring now") } footer: {
            Text(s.mode == "push"
                 ? "The server asks this iPhone for readings by push. iOS may delay or skip some requests; each batch covers everything since the last one."
                 : "Pull mode: readings are sent while Fengshui is open and when iOS gives it background time. Keep the app open for checks at the exact rate.")
        }
    }

    private func lastSection(_ s: MonitorSession) -> some View {
        Section("Last session") {
            LabeledContent("Status", value: s.status.capitalized)
            LabeledContent("Checks with data", value: "\(s.stats.intervalsWithData) of \(s.stats.intervals)")
            LabeledContent("Alerts", value: "\(s.stats.alerts)")
        }
    }

    private var agentText: String {
        guard let m = serverInfo?["monitor"] as? [String: Any] else { return "server not reachable" }
        return (m["agent"] as? Bool) == true ? "Claude" : "rules only (no key on the Mac)"
    }

    private var pushText: String {
        let server = ((serverInfo?["monitor"] as? [String: Any])?["push"] as? Bool) == true
        if env.monitor.pushToken != nil && server { return "on" }
        return "off"
    }

    private var pushExplanation: String {
        if env.monitor.pushToken == nil {
            return "This app can't receive pushes on a free Apple account (\(env.monitor.pushError ?? "not registered")). "
                + "With the paid developer program the server can ask for readings even when the app is closed (docs/PAID_ACCOUNT_SWITCH.md)."
        }
        return "Push requests are best effort: iOS limits background pushes to a few per hour."
    }

    static func durationText(_ h: Double) -> String {
        h < 1 ? "\(Int(h * 60)) min" : "\(h.formatted()) h"
    }

    private func reload() async {
        serverInfo = try? await env.server.client().health()
        session = (try? await env.monitor.refresh()) ?? env.monitor.cached
    }

    private func start() async {
        busy = true
        error = nil
        do { session = try await env.monitor.start(intervalMin: interval, durationH: duration) } catch { self.error = "\(error)" }
        busy = false
    }

    private func stop() async {
        busy = true
        do { session = try await env.monitor.stop() } catch { self.error = "\(error)" }
        busy = false
    }

    private func sendNow() async {
        busy = true
        do {
            try await env.monitor.sendReadings(trigger: "manual")
            session = env.monitor.cached
        } catch { self.error = "\(error)" }
        busy = false
    }
}
