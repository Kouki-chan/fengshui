import FengshuiKit
import Foundation
import Observation
import WatchConnectivity
import WatchKit

/// Watch-side WatchConnectivity: files to the phone, preferences and acks from it.
final class WatchSessionLink: NSObject, WatchFileTransport, WCSessionDelegate, @unchecked Sendable {
    var onPrefs: (@Sendable (RecordingPreferences) -> Void)?
    var onAck: (@Sendable (String) -> Void)?
    var onFlush: (@Sendable () -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(file: URL, metadata: [String: Any]) {
        guard WCSession.isSupported() else { return }
        WCSession.default.transferFile(file, metadata: metadata)
    }

    /// Live session heart rate for the phone's Data tab; dropped when the phone isn't reachable.
    func sendLive(heartRate: Double, ts: Double) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["live_hr": heartRate, "ts": ts], replyHandler: nil, errorHandler: nil)
    }

    var pendingTransfers: Int { WCSession.isSupported() ? WCSession.default.outstandingFileTransfers.count : 0 }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if let p = RecordingPreferences.from(context: session.receivedApplicationContext) { onPrefs?(p) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext ctx: [String: Any]) {
        if let p = RecordingPreferences.from(context: ctx) { onPrefs?(p) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if message["flush"] as? Bool == true { onFlush?() }
    }

    func session(_ session: WCSession, didReceiveUserInfo info: [String: Any] = [:]) {
        if let id = info["ack"] as? String { onAck?(id) }
    }
}

/// Owns the recorder and drives it from background refresh (spec §7.1, §7.4).
@MainActor
@Observable
final class WatchController {
    static let shared = WatchController()

    let link = WatchSessionLink()
    let recorder: WatchRecorder
    let session = WorkoutSessionController()
    var prefs = RecordingPreferences()
    var lastWake: Date?
    var lastReport: WatchRecorder.Report?
    var pendingFiles = 0

    /// watchOS gives a background refresh task a short budget; leave room for scheduling.
    static let refreshBudget: TimeInterval = 12

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("outbox")
        let prefs = (UserDefaults.standard.data(forKey: "recording"))
            .flatMap { try? JSONDecoder().decode(RecordingPreferences.self, from: $0) } ?? RecordingPreferences()
        self.prefs = prefs
        recorder = WatchRecorder(accel: SensorRecorderAdapter(), snapshots: SnapshotAdapter(), battery: WatchBattery(),
                                 transport: link, state: DefaultsStore(), clock: SystemClock(), outboxDir: dir, prefs: prefs)
        link.onPrefs = { p in Task { @MainActor in await WatchController.shared.apply(p) } }
        link.onAck = { id in Task { @MainActor in await WatchController.shared.ack(id) } }
        link.onFlush = { Task { @MainActor in await WatchController.shared.wake() } }
        link.activate()
        session.recorder = recorder
        session.onLiveHR = { [link] bpm, ts in link.sendLive(heartRate: bpm, ts: ts) }
    }

    func apply(_ p: RecordingPreferences) async {
        prefs = p
        UserDefaults.standard.set(try? JSONEncoder().encode(p), forKey: "recording")
        await recorder.update(prefs: p)
        scheduleRefresh()
    }

    func ack(_ id: String) async {
        await recorder.acknowledge(id)
        pendingFiles = recorder.outbox.pending.count
    }

    func wake() async {
        let r = await recorder.wake(deadline: Date().addingTimeInterval(Self.refreshBudget))
        lastReport = r
        lastWake = Date()
        pendingFiles = recorder.outbox.pending.count
        ComplicationController.reload()
    }

    func scheduleRefresh() {
        let next = Date().addingTimeInterval(Double(prefs.snapshotIntervalMin) * 60)
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: next, userInfo: nil) { _ in }
    }
}

/// Background-task entry point.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        Task { @MainActor in WatchController.shared.scheduleRefresh() }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            nonisolated(unsafe) let t = task
            switch task {
            case is WKApplicationRefreshBackgroundTask:
                Task { @MainActor in
                    await WatchController.shared.wake()
                    WatchController.shared.scheduleRefresh()
                    t.setTaskCompletedWithSnapshot(false)
                }
            default:
                t.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
