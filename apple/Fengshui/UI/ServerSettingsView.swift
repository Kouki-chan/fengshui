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
                        else { status = "No Fengshui server found (is scripts/run_server.sh running?)" }
                        busy = false
                    }
                }
                SecureField("Token from run_server.sh", text: $token)
                    .accessibilityIdentifier("server.token")
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
        }
    }

    private func save() async {
        try? env.db.setPreference(ServerSync.urlKey, url.trimmingCharacters(in: .whitespaces), now: env.clock.now)
        env.secrets.set(SecretKey.serverToken, token.trimmingCharacters(in: .whitespaces))
        try? env.db.setPreference(EngineRunner.locationKey, location, now: env.clock.now)
    }

    private func test() async {
        status = await env.server.reachable() ? "Connected ✓" : "Can't reach the server"
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        busy = true
        do { try await work(); status = "Done ✓" } catch { status = "\(error)" }
        busy = false
    }
}
