import CoreMotion
import FengshuiKit
import Foundation
import WatchKit

/// Tier 1: CMSensorRecorder, 50 Hz, kept by watchOS for ~3 days (spec §7.1).
final class SensorRecorderAdapter: AccelerometerRecorder, @unchecked Sendable {
    private let recorder = CMSensorRecorder()

    var isAvailable: Bool { CMSensorRecorder.isAccelerometerRecordingAvailable() }

    func arm(duration: TimeInterval) {
        recorder.recordAccelerometer(forDuration: duration)
    }

    func samples(from: Double, to: Double) async throws -> [SensorSample] {
        guard let list = recorder.accelerometerData(from: Date(timeIntervalSince1970: from),
                                                    to: Date(timeIntervalSince1970: to)) else { return [] }
        var out: [SensorSample] = []
        out.reserveCapacity(Int((to - from) * 50))
        for case let d as CMRecordedAccelerometerData in list {
            let a = d.acceleration
            out.append(SensorSample(ts: d.startDate.timeIntervalSince1970, values: [a.x, a.y, a.z]))
        }
        return out
    }
}

extension CMSensorDataList: @retroactive Sequence {
    public func makeIterator() -> NSFastEnumerationIterator { NSFastEnumerationIterator(self) }
}

/// Tier 2: gyroscope (rad/s), barometer (kPa) and compass heading (°) for a few seconds.
/// Heading is computed from the raw magnetometer + device-motion gravity (FengshuiKit
/// `Compass`), so the watch never asks for location; location context comes only from
/// the iPhone (DECISIONS D-11).
final class SnapshotAdapter: SnapshotSensors, @unchecked Sendable {
    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var buffers: [Sensor: [SensorSample]] = [:]
    private var gravity: [Double]?

    init() { queue.maxConcurrentOperationCount = 1 }

    func capture(seconds: Double, rateHz: Double, sensors: Set<Sensor>) async throws -> [Sensor: [SensorSample]] {
        lock.withLock { buffers = [:]; gravity = nil }
        let wantGyro = sensors.contains(.gyro), wantCompass = sensors.contains(.compass)
        if (wantGyro || wantCompass), motion.isDeviceMotionAvailable {
            // Device motion gives both rotation rate and gravity (needed for tilt compensation).
            motion.deviceMotionUpdateInterval = 1 / rateHz
            motion.startDeviceMotionUpdates(to: queue) { [weak self] m, _ in
                guard let self, let m else { return }
                let ts = Date().timeIntervalSince1970
                self.lock.withLock { self.gravity = [m.gravity.x, m.gravity.y, m.gravity.z] }
                if wantGyro {
                    self.append(.gyro, SensorSample(ts: ts, values: [m.rotationRate.x, m.rotationRate.y, m.rotationRate.z]))
                }
            }
        }
        if wantCompass, motion.isMagnetometerAvailable {
            motion.magnetometerUpdateInterval = 1 / rateHz
            motion.startMagnetometerUpdates(to: queue) { [weak self] d, _ in
                guard let self, let d, let g = self.lock.withLock({ self.gravity }) else { return }
                let f = d.magneticField
                if let h = Compass.heading(gravity: g, magnetic: [f.x, f.y, f.z]) {
                    self.append(.compass, SensorSample(ts: Date().timeIntervalSince1970, values: [h]))
                }
            }
        }
        if sensors.contains(.baro), CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: queue) { [weak self] d, _ in
                guard let d else { return }
                self?.append(.baro, SensorSample(ts: Date().timeIntervalSince1970, values: [d.pressure.doubleValue]))
            }
        }
        try await Task.sleep(for: .seconds(seconds))
        motion.stopDeviceMotionUpdates()
        motion.stopMagnetometerUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        return lock.withLock { buffers }
    }

    private func append(_ s: Sensor, _ x: SensorSample) { lock.withLock { buffers[s, default: []].append(x) } }
}

struct WatchBattery: BatteryState {
    var level: Double {
        let d = WKInterfaceDevice.current()
        d.isBatteryMonitoringEnabled = true
        return d.batteryLevel < 0 ? 1 : Double(d.batteryLevel)   // −1 = unknown (simulator)
    }
    var isLowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
}

final class DefaultsStore: KeyValueStore, @unchecked Sendable {
    private let d = UserDefaults.standard
    func double(_ key: String) -> Double? { d.object(forKey: key) as? Double }
    func set(_ value: Double, _ key: String) { d.set(value, forKey: key) }
    func string(_ key: String) -> String? { d.string(forKey: key) }
    func set(_ value: String, _ key: String) { d.set(value, forKey: key) }
}
