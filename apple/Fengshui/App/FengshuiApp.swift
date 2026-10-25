import SwiftUI

@main
struct FengshuiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel?
    @State private var startupError: String?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
            let env = try AppEnvironment.make()
            if !env.isTestMode { BackgroundTaskID.register(env: env) }
            AppDelegate.scheduler = env.windDown
            _model = State(initialValue: AppModel(env: env))
        } catch {
            _startupError = State(initialValue: "\(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                RootView(model: model)
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active { Task { await model.appBecameActive() } }
                        if phase == .background, !model.env.isTestMode {
                            BackgroundTaskID.scheduleRefresh()
                            BackgroundTaskID.scheduleProcessing()
                        }
                    }
            } else {
                ContentUnavailableView("Fengshui couldn't start", systemImage: "exclamationmark.triangle",
                                       description: Text(startupError ?? "unknown error"))
            }
        }
    }
}

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.onboardingDone {
            MainTabs(model: model)
        } else {
            OnboardingView(model: model)
        }
    }
}

struct MainTabs: View {
    let model: AppModel

    var body: some View {
        TabView {
            Tab("Today", systemImage: "sun.max") {
                NavigationStack { TodayView(env: model.env) }
            }
            Tab("Data", systemImage: "waveform.path.ecg") {
                NavigationStack { DataView(env: model.env) }
            }
            Tab("Ask", systemImage: "bubble.left.and.text.bubble.right") {
                NavigationStack { AskView(env: model.env) }
            }
            Tab("Settings", systemImage: "gear") {
                NavigationStack { SettingsView(model: model) }
            }
        }
    }
}

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        List {
            Section("Wind-down") {
                NavigationLink("Wind-down & notifications") { WindDownSettingsView(env: model.env) }
                    .accessibilityIdentifier("settings.winddown")
                SigningRow()
            }
            Section("Claude") {
                NavigationLink("Claude") { ClaudeSettingsView(env: model.env) }
                    .accessibilityIdentifier("settings.claude")
            }
            Section("Mac server") {
                NavigationLink("Server & compute") { ServerSettingsView(env: model.env) }
                    .accessibilityIdentifier("settings.server")
            }
            Section("Watch") {
                NavigationLink("Recording") { RecordingView(env: model.env) }
                    .accessibilityIdentifier("settings.recording")
            }
            Section("Context") {
                NavigationLink("Places") { PlacesView(env: model.env) }
                    .accessibilityIdentifier("settings.places")
            }
            Section("Device test") {
                NavigationLink("Diagnostics") { DiagnosticsView(env: model.env) }
                    .accessibilityIdentifier("settings.diagnostics")
                NavigationLink("Export database") { ExportDatabaseView(env: model.env) }
                    .accessibilityIdentifier("settings.export")
            }
            Section("Debug") {
                NavigationLink("Data & sync") { DebugView(env: model.env) }
                    .accessibilityIdentifier("settings.debug")
                NavigationLink("Notification log") { NotificationLogView(env: model.env) }
                    .accessibilityIdentifier("settings.notiflog")
            }
        }
        .navigationTitle("Settings")
    }
}
