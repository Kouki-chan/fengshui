import SwiftUI

@main
struct FengshuiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel?
    @State private var startupError: String?
    @State private var appearance = Appearance()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
            let env = try AppEnvironment.make()
            if !env.isTestMode { BackgroundTaskID.register(env: env) }
            AppDelegate.scheduler = env.windDown
            AppDelegate.monitor = env.monitor
            AppDelegate.inbox = env.inbox
            AppDelegate.registerForPush = !env.isTestMode
            _model = State(initialValue: AppModel(env: env))
        } catch {
            _startupError = State(initialValue: "\(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                RootView(model: model)
                    .environment(appearance)
                    .environment(\.theme, appearance.theme)
                    .tint(appearance.theme.tint)
                    .preferredColorScheme(appearance.mode.colorScheme)
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active {
                            model.ui.refreshKey()
                            Task { await model.appBecameActive() }
                        }
                        if phase != .active { model.appLeftForeground() }
                        if phase == .background, !model.env.isTestMode {
                            BackgroundTaskID.scheduleRefresh()
                            BackgroundTaskID.scheduleProcessing()
                        }
                    }
            } else {
                ContentUnavailableView("HealthBot couldn't start", systemImage: "exclamationmark.triangle",
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
    @Bindable var ui: UIState

    init(model: AppModel) {
        self.model = model
        ui = model.ui
    }

    var body: some View {
        let env = model.env
        TabView(selection: $ui.tab) {
            Tab("Today", systemImage: "sun.max", value: UIState.TabID.today) {
                NavigationStack { TodayView(env: env, ui: ui).inboxToolbar(env) }
            }
            Tab("Data", systemImage: "waveform.path.ecg", value: UIState.TabID.data) {
                NavigationStack { DataView(env: env, model: ui.data).inboxToolbar(env) }
            }
            Tab("Monitor", systemImage: "heart.text.square", value: UIState.TabID.monitor) {
                NavigationStack { MonitorView(env: env).inboxToolbar(env) }
            }
            Tab("Ask", systemImage: "bubble.left.and.text.bubble.right", value: UIState.TabID.ask) {
                NavigationStack { AskView(env: env, ui: ui).inboxToolbar(env) }
            }
            .badge(ui.ask.unseen)
            Tab("Reports", systemImage: "doc.richtext", value: UIState.TabID.reports) {
                NavigationStack { ReportsView(env: env).inboxToolbar(env) }
            }
        }
        .sheet(isPresented: $ui.showSettings, onDismiss: { ui.showProfile = false }) {
            SettingsSheet(model: model, ui: ui)
        }
        .environment(ui)
        .task { ui.observeInbox() }
    }
}

/// Settings in a sheet, opened from the profile avatar (or straight on Profile from Today).
struct SettingsSheet: View {
    let model: AppModel
    let ui: UIState
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            SettingsView(model: model)
                .navigationDestination(for: String.self) { _ in ProfileView(env: model.env) }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { ui.showSettings = false }.accessibilityIdentifier("settings.done")
                    }
                }
        }
        .environment(ui)
        .onAppear { if ui.showProfile { path = ["profile"] } }
    }
}

struct SettingsView: View {
    let model: AppModel
    @Environment(\.theme) private var theme
    @Environment(UIState.self) private var ui: UIState?

    var body: some View {
        List {
            Section {
                NavigationLink(value: "profile") {
                    HStack(spacing: 14) {
                        ProfileAvatar(initials: ui?.profile.initials ?? "", size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ui.map { $0.profile.name.isEmpty ? "Your profile" : $0.profile.name } ?? "Your profile")
                                .font(.headline)
                            Text(profileSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("settings.profile")
            }
            Section {
                HStack(spacing: 14) {
                    HealthBotLogo(size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("HealthBot").font(.title3.weight(.bold))
                        Text("Your activity, sleep and vitals, explained.").font(.caption).foregroundStyle(.secondary)
                        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                            Text("Version \(v)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.vertical, 4)
                row("Appearance", "paintpalette.fill", theme.highlight, id: "settings.appearance") { AppearanceView() }
            }
            Section("Wind-down") {
                row("Wind-down & notifications", "moon.zzz.fill", theme.sleep, id: "settings.winddown") {
                    WindDownSettingsView(env: model.env)
                }
                SigningRow()
            }
            Section("Agent") {
                row("Agent", "sparkles", theme.highlight, id: "settings.claude") { ClaudeSettingsView(env: model.env) }
            }
            Section("Mac server") {
                row("Server & compute", "desktopcomputer", theme.tint, id: "settings.server") { ServerSettingsView(env: model.env) }
            }
            Section("Watch") {
                row("Recording", "applewatch", theme.activity, id: "settings.recording") { RecordingView(env: model.env) }
            }
            Section("Context") {
                row("Places", "mappin.and.ellipse", theme.activity, id: "settings.places") { PlacesView(env: model.env) }
            }
            Section("Device test") {
                row("Diagnostics", "stethoscope", .gray, id: "settings.diagnostics") { DiagnosticsView(env: model.env) }
                row("Export database", "square.and.arrow.up", .gray, id: "settings.export") { ExportDatabaseView(env: model.env) }
            }
            Section("Debug") {
                row("Data & sync", "ladybug.fill", .gray, id: "settings.debug") { DebugView(env: model.env) }
                row("Notification log", "bell.fill", .gray, id: "settings.notiflog") { NotificationLogView(env: model.env) }
            }
        }
        .themedList()
        .navigationTitle("Settings")
    }

    private var profileSummary: String {
        guard let p = ui?.profile else { return "Goals and details HealthBot uses" }
        if p.goals.isEmpty { return "Add your goals so HealthBot can tailor its notes" }
        return p.goals.joined(separator: " · ")
    }

    private func row<D: View>(_ title: String, _ icon: String, _ tint: Color, id: String,
                              @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink(destination: destination) {
            Label { Text(title) } icon: { IconBadge(systemImage: icon, tint: tint, size: 28) }
        }
        .accessibilityIdentifier(id)
    }
}

/// Settings → Appearance: the colour scheme and light/dark mode.
struct AppearanceView: View {
    @Environment(Appearance.self) private var appearance

    var body: some View {
        @Bindable var appearance = appearance
        List {
            Section {
                Picker("Mode", selection: $appearance.mode) {
                    ForEach(Appearance.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearance.mode")
            } header: { Text("Light or dark") }
            Section {
                ForEach(Theme.all) { t in
                    Button {
                        withAnimation(.snappy) { appearance.theme = t }
                    } label: { ThemeRow(theme: t, selected: t.id == appearance.theme.id) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("appearance.theme.\(t.id)")
                    .accessibilityAddTraits(t.id == appearance.theme.id ? .isSelected : [])
                }
            } header: { Text("Colour scheme") } footer: {
                Text("Each scheme has a light and a dark version, so text stays easy to read either way.")
            }
        }
        .themedList()
        .navigationTitle("Appearance")
    }
}

/// A scheme as a mood-board strip of its five colours, with a preview of its hero gradient.
struct ThemeRow: View {
    let theme: Theme
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(theme.name).font(.headline)
                    Text(theme.mood).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2).foregroundStyle(selected ? theme.tint : Color.secondary)
            }
            HStack(spacing: 6) {
                ForEach(Array(theme.swatches.enumerated()), id: \.offset) { _, c in
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c).frame(height: 34)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.black.opacity(0.06)))
                }
            }
            HStack(spacing: 8) {
                Capsule().fill(theme.heroGradient).frame(height: 8)
                ForEach([theme.heart, theme.activity, theme.sleep], id: \.self) { c in Circle().fill(c).frame(width: 12, height: 12) }
            }
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
    }
}
