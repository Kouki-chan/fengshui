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

    private var health: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "heart.text.square").font(.system(size: 56)).foregroundStyle(.pink)
            Text("Health data").font(.title.bold())
            Text("Fengshui reads all your Health data once (this can take a few minutes), then keeps up with new samples. Nothing leaves your iPhone except to your own Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Allow Health access") { Task { await model.requestHealth() } }
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
