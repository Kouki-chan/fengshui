import SwiftUI

/// Settings → Server & compute (spec §12, §15): server URL (Bonjour or manual), token
/// (Keychain), compute location, and manual sync / archive.
struct ServerSettingsView: View {
    let env: AppEnvironment
    @State private var url = ""
    @State private var token = ""
    @State private var location = EngineRunner.Location.auto
    @State private var status = ""
    @State private var busy = false
    @State private var serverInfo: [String: Any]?

    var body: some View {
        Form {
            Section {
                TextField("http://mac.local:8765", text: $url)
                    .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                    .accessibilityIdentifier("server.url")
                Button("Find on this network") {
                    Task {
                        busy = true
                        if let u = await ServerDiscovery.find() { url = u.absoluteString; status = "Found \(u.host() ?? "")" }
                        else { status = "No HealthBot server found (is scripts/run_server.sh running?)" }
                        busy = false
                    }
                }
                HStack {
                    SecureField("Token from run_server.sh", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("server.token")
                    // Apple's paste button: reads the clipboard (e.g. copied on the Mac) without a prompt.
                    PasteButton(payloadType: String.self) { items in
                        if let t = items.first { token = t.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    .labelStyle(.iconOnly).buttonBorderShape(.capsule)
                }
            } header: { Text("Mac server") } footer: {
                Text("Syncs over Wi-Fi only. The token is stored in the Keychain.")
            }
            Section {
                Picker("Run the engine on", selection: $location) {
                    Text("iPhone").tag(EngineRunner.Location.phone)
                    Text("Mac server").tag(EngineRunner.Location.server)
                    Text("Automatic").tag(EngineRunner.Location.auto)
                }
                .accessibilityIdentifier("server.location")
            } footer: {
                Text("Automatic uses the Mac when Low Power Mode is on or more than a day of watch data is waiting, if the Mac is reachable.")
            }
            Section {
                LabeledContent("Server agent", value: agentText)
                    .accessibilityIdentifier("server.agent")
                LabeledContent("Apple push", value: pushText)
                    .accessibilityIdentifier("server.push")
            } header: { Text("Health monitor delivery") } footer: {
                Text("The server agent decides whether a reading is worth an alert. With push, the server can ask this "
                     + "iPhone for readings even when HealthBot is closed.")
            }
            Section {
                Button("Save & test connection") { Task { await save(); await test() } }
                    .accessibilityIdentifier("server.save")
                Button("Sync now") { Task { await run { _ = try await env.server.sync(); _ = try await env.server.archive() } } }
                    .disabled(busy)
                if !status.isEmpty { Text(status).font(.caption).accessibilityIdentifier("server.status") }
            }
        }
        .navigationTitle("Server & compute")
        .task {
            url = env.server.baseURL?.absoluteString ?? ""
            token = env.secrets.get(SecretKey.serverToken) ?? ""
            location = env.engine.location
            await loadServerInfo()
        }
    }

    private var monitorInfo: [String: Any]? { serverInfo?["monitor"] as? [String: Any] }

    private var agentText: String {
        guard let m = monitorInfo else { return "server not reachable" }
        return (m["agent"] as? Bool) == true ? "FengShui" : "rules only (no key on the Mac)"
    }

    /// On only when this iPhone has a push token and the server can send pushes.
    private var pushText: String {
        if env.monitor.pushToken == nil { return "off (needs the paid developer account)" }
        guard let m = monitorInfo else { return "server not reachable" }
        return (m["push"] as? Bool) == true ? "on" : "off on the server"
    }

    private func loadServerInfo() async {
        guard var c = try? env.server.client() else { serverInfo = nil; return }
        c.timeout = 8
        serverInfo = try? await c.health()
    }

    private func save() async {
        url = ServerDiscovery.normalize(url)
        try? env.db.setPreference(ServerSync.urlKey, url, now: env.clock.now)
        env.secrets.set(SecretKey.serverToken, token.trimmingCharacters(in: .whitespaces))
        try? env.db.setPreference(EngineRunner.locationKey, location, now: env.clock.now)
    }

    private func test() async {
        busy = true
        status = "Testing…"
        status = await env.server.connectionProblem() ?? "Connected ✓"
        await loadServerInfo()
        busy = false
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        busy = true
        do { try await work(); status = "Done ✓" } catch { status = "\(error)" }
        busy = false
    }
}
