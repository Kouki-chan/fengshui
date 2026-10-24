import SwiftUI

@main
struct FengshuiApp: App {
    @State private var model: AppModel?
    @State private var startupError: String?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
            let env = try AppEnvironment.make()
            if !env.isTestMode { BackgroundTaskID.register(env: env) }
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
                NavigationStack { Text("Today").navigationTitle("Today") }
            }
            Tab("Ask", systemImage: "bubble.left.and.text.bubble.right") {
                NavigationStack { Text("Ask").navigationTitle("Ask") }
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
            Section("Watch") {
                NavigationLink("Recording") { RecordingView(env: model.env) }
                    .accessibilityIdentifier("settings.recording")
            }
            Section("Context") {
                NavigationLink("Places") { PlacesView(env: model.env) }
                    .accessibilityIdentifier("settings.places")
            }
            Section("Debug") {
                NavigationLink("Data & sync") { DebugView(env: model.env) }
                    .accessibilityIdentifier("settings.debug")
            }
        }
        .navigationTitle("Settings")
    }
}
