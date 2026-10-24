import CoreMotion
import FengshuiKit
import Foundation
import HealthKit
import Observation

/// Tier 3 (spec §7.1): a user-started session. HKWorkoutSession (.other) keeps the app
/// running and gives HR every ~5 s; device motion at 50 Hz and the altimeter run alongside.
/// Ends only when the user stops it — never left running to get background sensors.
@MainActor
@Observable
final class WorkoutSessionController: NSObject {
    private let store = HKHealthStore()
    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let queue = OperationQueue()
    /// Latest gravity vector, for tilt-compensated compass heading (no location needed).
    private let gravity = GravityBox()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private let assembler = SessionAssembler()
    var recorder: WatchRecorder?
    var running = false
    var startedAt: Date?
    var lastHR: Double?
    var error: String?

    func start(prefs: RecordingPreferences) async {
        guard prefs.sessionsAllowed, !running else { return }
        do {
            let types: Set<HKSampleType> = [HKQuantityType(.heartRate)]
            try await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: types)
            let config = HKWorkoutConfiguration()
            config.activityType = .other
            config.locationType = .unknown
            let s = try HKWorkoutSession(healthStore: store, configuration: config)
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            b.delegate = self
            session = s
            builder = b
            let now = Date()
            await assembler.begin(at: now.timeIntervalSince1970)
            s.startActivity(with: now)
            try await b.beginCollection(at: now)
            startSensors(prefs)
            running = true
            startedAt = now
        } catch {
            self.error = "\(error)"
        }
    }

    private func startSensors(_ prefs: RecordingPreferences) {
        queue.maxConcurrentOperationCount = 1
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1 / 50
            motion.startDeviceMotionUpdates(to: queue) { [assembler, gravity] m, _ in
                guard let m else { return }
                let ts = Date().timeIntervalSince1970
                gravity.set([m.gravity.x, m.gravity.y, m.gravity.z])
                // Total acceleration (user + gravity) in g, like CMSensorRecorder, so features match tier 1.
                let a = SensorSample(ts: ts, values: [m.userAcceleration.x + m.gravity.x, m.userAcceleration.y + m.gravity.y,
                                                      m.userAcceleration.z + m.gravity.z])
                let g = SensorSample(ts: ts, values: [m.rotationRate.x, m.rotationRate.y, m.rotationRate.z])
                Task {
                    await assembler.add(.accel, [a])
                    if prefs.gyroscope { await assembler.add(.gyro, [g]) }
                }
            }
        }
        if prefs.compass, motion.isMagnetometerAvailable {
            motion.magnetometerUpdateInterval = 1 / 50
            motion.startMagnetometerUpdates(to: queue) { [assembler, gravity] d, _ in
                guard let d, let g = gravity.get() else { return }
                let f = d.magneticField
                guard let h = Compass.heading(gravity: g, magnetic: [f.x, f.y, f.z]) else { return }
                let s = SensorSample(ts: Date().timeIntervalSince1970, values: [h])
                Task { await assembler.add(.compass, [s]) }
            }
        }
        if prefs.barometer, CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: queue) { [assembler] d, _ in
                guard let d else { return }
                let s = SensorSample(ts: Date().timeIntervalSince1970, values: [d.pressure.doubleValue])
                Task { await assembler.add(.baro, [s]) }
            }
        }
    }

    func stop() async {
        guard running, let session, let builder else { return }
        motion.stopDeviceMotionUpdates()
        motion.stopMagnetometerUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        session.end()
        do {
            try await builder.endCollection(at: Date())
            _ = try await builder.finishWorkout()      // saved to Health as a workout (share permission)
        } catch {
            self.error = "\(error)"
        }
        running = false
        // Tier-3 files transfer when the session ends (spec §7.4).
        for hour in await assembler.finish() {
            _ = try? await recorder?.send(hour, tier: 3, gaps: [])
        }
        self.session = nil
        self.builder = nil
    }
}

extension WorkoutSessionController: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ b: HKLiveWorkoutBuilder, didCollectDataOf types: Set<HKSampleType>) {
        let hrType = HKQuantityType(.heartRate)
        guard types.contains(hrType), let q = b.statistics(for: hrType)?.mostRecentQuantity() else { return }
        let bpm = q.doubleValue(for: .count().unitDivided(by: .minute()))
        let s = SensorSample(ts: Date().timeIntervalSince1970, values: [bpm])
        Task { @MainActor in
            self.lastHR = bpm
            await self.assembler.add(.hrSession, [s])
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ b: HKLiveWorkoutBuilder) {}
}

final class GravityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [Double]?
    func set(_ x: [Double]) { lock.withLock { v = x } }
    func get() -> [Double]? { lock.withLock { v } }
}
