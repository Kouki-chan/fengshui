import SwiftUI

/// Onboarding (spec §15). Phase 1 covers welcome → Health → backfill; later phases
/// insert recording preferences, places, sleep questions and notifications.
struct OnboardingView: View {
    @Bindable var model: AppModel
    @Environment(\.theme) private var theme

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
            .themedBackground()
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            Spacer()
            HealthBotLogo(size: 112)
            VStack(spacing: 8) {
                Text("HealthBot").font(.largeTitle.bold())
                Text("Understands your activity and sleep from your iPhone and Apple Watch, answers your questions, and tells you when to start winding down.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                feature("waveform.path.ecg", theme.heart, "Live vitals", "Heart rate, HRV, oxygen and breathing from your watch.")
                feature("sparkles", theme.highlight, "Ask anything", "An AI agent that reads your processed data, never raw sensors.")
                feature("doc.richtext.fill", theme.tint, "Reports for your doctor", "Shareable PDFs with charts and a summary.")
                feature("lock.fill", theme.sleep, "Private", "Data stays on your iPhone and your own Mac.")
            }
            .padding(.top, 8)
            Spacer()
            primary("Get started") { model.step = .health }
                .accessibilityIdentifier("onboarding.start")
        }
    }

    private func feature(_ icon: String, _ tint: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            IconBadge(systemImage: icon, tint: tint, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }

    private var notificationsStep: some View {
        VStack(spacing: 24) {
            Spacer()
            IconBadge(systemImage: "bell.badge.fill", tint: theme.highlight, size: 88)
            Text("Wind-down reminders").font(.title.bold())
            Text("HealthBot reminds you when it's time to start winding down, and again when you get home late.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Spacer()
            primary("Allow notifications") { Task { await model.notificationsDone(requestPermission: true) } }
                .accessibilityIdentifier("onboarding.notifications")
            Button("Not now") { Task { await model.notificationsDone(requestPermission: false) } }
        }
    }

    private var health: some View {
        VStack(spacing: 24) {
            Spacer()
            IconBadge(systemImage: "heart.text.square.fill", tint: theme.heart, size: 88)
            Text("Health data").font(.title.bold())
            Text("HealthBot reads all your Health data once (this can take a few minutes), then keeps up with new samples. Nothing leaves your iPhone except to your own Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            if let err = model.healthAuthError {
                Text("Health permission failed: \(err)").font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("onboarding.healthError")
            }
            primary(model.healthAuthError == nil ? "Allow Health access" : "Try again") {
                Task { await model.requestHealth() }
            }
            .accessibilityIdentifier("onboarding.health")
        }
    }
}

struct BackfillView: View {
    @Bindable var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            HealthBotLogo(size: 72)
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
            Button { model.finishOnboarding() } label: {
                Text("Continue").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
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
                Text("Used for the first few nights, until HealthBot has learned from your sleep data.")
            }
            Button("Continue") {
                model.sleepDone(workdayWake: Self.hhmm(workday), freedayWake: Self.hhmm(freeday), bedtime: Self.hhmm(bedtime))
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("sleep.continue")
        }
        .themedList()
        .navigationTitle("Sleep")
    }
}
