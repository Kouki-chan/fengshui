import BackgroundTasks
import Foundation
import Observation

/// UI-facing state. Owns nothing heavy; everything real lives in AppEnvironment.
@MainActor
@Observable
final class AppModel {
    /// Spec §15 order; steps for later phases are inserted where they belong.
    enum OnboardingStep: String, CaseIterable, Codable {
        case welcome, health, recording, places, sleep, notifications, backfill
    }

    let env: AppEnvironment
    var onboardingDone: Bool
    var step: OnboardingStep = .welcome
    var backfill: HealthSync.Progress?
    var backfillComplete = false
    var backfillError: String?

    init(env: AppEnvironment) {
        self.env = env
        onboardingDone = (try? env.db.preference("onboarding_done", as: Bool.self)) ?? false
    }

    func requestHealth() async {
        do {
            try await env.health.requestAuthorization(read: env.healthSync.readableTypes())
            env.log.add("health_auth", "requested \(env.healthSync.readableTypes().count) types")
        } catch {
            env.log.add("health_auth_error", "\(error)")
        }
        step = .recording
    }

    func placesDone() async { step = .sleep }

    func sleepDone(workdayWake: String, freedayWake: String, bedtime: String) {
        // Cold-start inputs for wind-down until ≥ 3 nights exist (spec §10.2).
        try? env.db.setPreference("onboarding_sleep", ["workday_wake": workdayWake, "freeday_wake": freedayWake,
                                                       "bedtime": bedtime], now: env.clock.now)
        step = .notifications
    }

    func notificationsDone(requestPermission: Bool) async {
        if requestPermission {
            let ok = await env.notifications.requestAuthorization()
            env.log.add("notif_auth", ok ? "granted" : "denied")
        }
        step = .backfill
        await runBackfill()
    }

    func runBackfill() async {
        backfillError = nil
        let onProgress: @Sendable (HealthSync.Progress) -> Void = { [weak self] p in
            Task { @MainActor in self?.backfill = p }
        }
        do {
            try await env.healthSync.syncAll(progress: onProgress)
            // A separate flag: progress updates hop to the main actor asynchronously and
            // may land after syncAll returns, so `backfill` alone can't signal completion.
            backfillComplete = true
        } catch {
            // Resumable: anchors are saved per page, so "Retry" continues where it stopped.
            backfillError = "\(error)"
        }
    }

    func finishOnboarding() {
        try? env.db.setPreference("onboarding_done", true, now: env.clock.now)
        onboardingDone = true
        Task {
            await env.delivery.register()
            await env.places.start()
            await env.engine.run(trigger: "onboarding")
        }
    }

    /// Launch / foreground hook (fallback for background delivery, spec §6.1).
    func appBecameActive() async {
        guard onboardingDone else { return }
        await env.delivery.register()
        await env.places.start()
        await env.delivery.syncNow(trigger: "foreground")
        await env.windDown.reconcileDelivered()
        if let expiry = SigningExpiry.expirationDate() {
            await SigningExpiry.scheduleReminder(expiry: expiry, now: env.clock.now, center: env.notifications,
                                                 timeZone: env.timeZone)
        }
    }
}

/// BGTaskScheduler identifiers (also listed in Info.plist).
enum BackgroundTaskID {
    static let refresh = "com.chevin.fengshui.refresh"
    static let processing = "com.chevin.fengshui.processing"

    static func register(env: AppEnvironment) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refresh, using: nil) { task in
            scheduleRefresh()
            run(task) { await env.delivery.syncNow(trigger: "bg_refresh") }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processing, using: nil) { task in
            scheduleProcessing()
            run(task) { await env.delivery.syncNow(trigger: "bg_processing") }
        }
    }

    /// BGTask isn't Sendable; the system only touches it from our handler and the
    /// expiration callback, so handing it to one Task is safe.
    private static func run(_ task: BGTask, _ work: @escaping @Sendable () async -> Void) {
        nonisolated(unsafe) let t = task
        let job = Task {
            await work()
            t.setTaskCompleted(success: !Task.isCancelled)
        }
        t.expirationHandler = { job.cancel() }
    }

    static func scheduleRefresh() {
        let r = BGAppRefreshTaskRequest(identifier: refresh)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    /// Nightly heavy work while charging (spec §9).
    static func scheduleProcessing() {
        let r = BGProcessingTaskRequest(identifier: processing)
        r.requiresExternalPower = true
        r.requiresNetworkConnectivity = false
        r.earliestBeginDate = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 2),
                                                        matchingPolicy: .nextTime)
        try? BGTaskScheduler.shared.submit(r)
    }
}
