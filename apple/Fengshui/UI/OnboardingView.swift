import SwiftUI

/// Onboarding (spec §15). Phase 1 covers welcome → Health → backfill; later phases
/// insert recording preferences, places, sleep questions and notifications.
struct OnboardingView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            Group {
                switch model.step {
                case .welcome: welcome
                case .health: health
                case .recording: RecordingView(env: model.env, onboarding: true) { model.step = .places }
                case .places: PlacesView(env: model.env, onboarding: true) { Task { await model.placesDone() } }
                case .sleep: SleepQuestionsView(model: model)
                case .notifications: notificationsStep
                case .backfill: BackfillView(model: model)
                }
            }
            .padding()
        }
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("Fengshui").font(.largeTitle.bold())
            Text("Understands your activity and sleep from your iPhone and Apple Watch, and tells you when to start winding down.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Get started") { model.step = .health }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("onboarding.start")
        }
    }

    private var notificationsStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "bell.badge").font(.system(size: 56)).foregroundStyle(.orange)
            Text("Wind-down reminders").font(.title.bold())
            Text("Fengshui reminds you when it's time to start winding down, and again when you get home late.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Spacer()
            Button("Allow notifications") { Task { await model.notificationsDone(requestPermission: true) } }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("onboarding.notifications")
            Button("Not now") { Task { await model.notificationsDone(requestPermission: false) } }
        }
    }

    private var health: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "heart.text.square").font(.system(size: 56)).foregroundStyle(.pink)
            Text("Health data").font(.title.bold())
            Text("Fengshui reads all your Health data once (this can take a few minutes), then keeps up with new samples. Nothing leaves your iPhone except to your own Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            if let err = model.healthAuthError {
                Text("Health permission failed: \(err)").font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("onboarding.healthError")
            }
            Button(model.healthAuthError == nil ? "Allow Health access" : "Try again") {
                Task { await model.requestHealth() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("onboarding.health")
        }
    }
}

struct BackfillView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("Reading your Health history").font(.title2.bold())
            if let p = model.backfill {
                ProgressView(value: Double(p.typesDone), total: Double(max(p.typesTotal, 1)))
                    .accessibilityIdentifier("backfill.progress")
                Text("\(p.rowsWritten) samples · \(p.typesDone)/\(p.typesTotal) types")
                    .monospacedDigit()
                    .accessibilityIdentifier("backfill.count")
                if let l = p.currentLabel, !p.finished {
                    Text(l).font(.caption).foregroundStyle(.secondary)
                }
                if !p.failedTypes.isEmpty {
                    Text("\(p.failedTypes.count) types skipped (they'll be retried): \(p.failedTypes.prefix(3).joined(separator: "; "))")
                        .font(.caption2).foregroundStyle(.orange)
                        .accessibilityIdentifier("backfill.skipped")
                }
            } else {
                ProgressView()
            }
            if let err = model.backfillError {
                Text(err).font(.caption).foregroundStyle(.red)
                Button("Retry") { Task { await model.runBackfill() } }
            }
            Spacer()
            Button("Continue") { model.finishOnboarding() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.backfillComplete)
                .accessibilityIdentifier("backfill.continue")
        }
    }
}

/// Cold-start sleep questions (spec §10.2): used until ≥ 3 nights of data exist.
struct SleepQuestionsView: View {
    let model: AppModel
    @State private var workday = Self.time(7, 0)
    @State private var freeday = Self.time(8, 30)
    @State private var bedtime = Self.time(23, 0)

    static func time(_ h: Int, _ m: Int) -> Date {
        Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
    }

    static func hhmm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    var body: some View {
        Form {
            Section {
                DatePicker("Workday wake-up", selection: $workday, displayedComponents: .hourAndMinute)
                DatePicker("Free-day wake-up", selection: $freeday, displayedComponents: .hourAndMinute)
                DatePicker("Usual bedtime", selection: $bedtime, displayedComponents: .hourAndMinute)
            } header: { Text("Your usual sleep") } footer: {
                Text("Used for the first few nights, until Fengshui has learned from your sleep data.")
            }
            Button("Continue") {
                model.sleepDone(workdayWake: Self.hhmm(workday), freedayWake: Self.hhmm(freeday), bedtime: Self.hhmm(bedtime))
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("sleep.continue")
        }
        .navigationTitle("Sleep")
    }
}
