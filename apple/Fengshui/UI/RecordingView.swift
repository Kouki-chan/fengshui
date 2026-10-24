import FengshuiKit
import SwiftUI

/// Spec §7.2: per-sensor toggles, tier-2 interval, whether sessions are allowed.
/// Shown once in onboarding, editable in Settings; mirrored to the watch.
struct RecordingView: View {
    let env: AppEnvironment
    var onboarding = false
    var onDone: () -> Void = {}
    @State private var prefs = RecordingPreferences()

    var body: some View {
        Form {
            Section {
                Toggle("Accelerometer (all day)", isOn: $prefs.accelerometer)
                    .accessibilityIdentifier("rec.accel")
            } header: { Text("Continuous") } footer: {
                Text("Recorded by watchOS in the background at 50 Hz and sent to your iPhone in hourly batches.")
            }
            Section {
                Toggle("Gyroscope", isOn: $prefs.gyroscope)
                Toggle("Barometer", isOn: $prefs.barometer)
                Toggle("Compass", isOn: $prefs.compass)
                Picker("Every", selection: $prefs.snapshotIntervalMin) {
                    ForEach(RecordingPreferences.allowedIntervals, id: \.self) { Text("\($0) min").tag($0) }
                }
                .accessibilityIdentifier("rec.interval")
                Stepper("Length \(Int(prefs.snapshotSeconds)) s", value: $prefs.snapshotSeconds,
                        in: RecordingPreferences.snapshotRange, step: 1)
            } header: { Text("Short snapshots") } footer: {
                Text("A few seconds of extra sensors whenever the watch wakes. Skipped below 30 % battery or in Low Power Mode.")
            }
            Section {
                Toggle("Allow recording sessions", isOn: $prefs.sessionsAllowed)
                Toggle("Heart rate every 5 s during sessions", isOn: $prefs.sessionHeartRate)
                    .disabled(!prefs.sessionsAllowed)
            } header: { Text("Sessions") } footer: {
                Text("You start and stop a session on the watch; it records everything at full rate.")
            }
            if onboarding {
                Button("Continue") { save(); onDone() }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("rec.continue")
            }
        }
        .navigationTitle("Recording")
        .task { prefs = env.recordingPreferences() }
        .onChange(of: prefs) { _, _ in if !onboarding { save() } }
    }

    private func save() { env.saveRecordingPreferences(prefs) }
}
