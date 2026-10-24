import FengshuiKit
import SwiftUI

@main
struct FengshuiWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            WatchStatusView(controller: .shared)
        }
    }
}

/// Status (recording tiers, last sync), session start/stop, read-only settings mirror (spec §15).
struct WatchStatusView: View {
    @Bindable var controller: WatchController

    var body: some View {
        List {
            Section("Recording") {
                row("Accelerometer", controller.prefs.accelerometer)
                row("Snapshots / \(controller.prefs.snapshotIntervalMin) min", controller.prefs.snapshotSensorsEnabled)
                if let w = controller.lastWake {
                    LabeledContent("Last wake", value: w.formatted(date: .omitted, time: .shortened))
                }
                LabeledContent("Waiting for iPhone", value: "\(controller.pendingFiles) files")
                if let r = controller.lastReport {
                    LabeledContent("Snapshot", value: r.snapshot)
                }
            }
            if controller.prefs.sessionsAllowed {
                Section("Session") {
                    if controller.session.running {
                        if let hr = controller.session.lastHR { LabeledContent("Heart rate", value: "\(Int(hr))") }
                        Button("Stop session", role: .destructive) { Task { await controller.session.stop() } }
                    } else {
                        Button("Start session") { Task { await controller.session.start(prefs: controller.prefs) } }
                    }
                }
            }
            Section {
                Button("Sync now") { Task { await controller.wake() } }
            } footer: {
                Text("Settings are changed on your iPhone.")
            }
        }
    }

    private func row(_ title: String, _ on: Bool) -> some View {
        LabeledContent(title, value: on ? "On" : "Off")
    }
}
