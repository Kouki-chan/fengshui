import Foundation
import Testing
@testable import FengshuiKit

// MARK: - Fakes shared by the watch-pipeline tests

/// Replays a synthetic 50 Hz wrist trace: still / walking / running segments with noise.
final class FakeAccelRecorder: AccelerometerRecorder, @unchecked Sendable {
    var isAvailable = true
    private(set) var armCount = 0
    /// Spans with no data at all (watch off / recorder paused).
    var holes: [ClosedRange<Double>] = []
    var failNext = false

    func arm(duration: TimeInterval) { armCount += 1 }

    func samples(from: Double, to: Double) async throws -> [SensorSample] {
        if failNext { failNext = false; throw CocoaError(.fileReadUnknown) }
        return SyntheticTrace.accel(from: from, to: to).filter { s in !holes.contains { $0.contains(s.ts) } }
    }
}

enum SyntheticTrace {
    /// Deterministic, realistic-ish wrist accelerometer: alternating 10-min blocks of
    /// desk / walking / running, gravity on z, noise from a fixed LCG.
    static func accel(from: Double, to: Double, rate: Double = 50) -> [SensorSample] {
        var out: [SensorSample] = []
        // Timestamps from the sample index, not by accumulating 1/rate (float drift would
        // push samples across minute boundaries).
        let first = (from * rate).rounded(.up)
        var i = 0.0
        var t = first / rate
        var seed: UInt64 = UInt64(from) &* 6364136223846793005 &+ 1442695040888963407
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Double(seed >> 33) / Double(1 << 31) - 0.5) * 2
        }
        while t < to {
            let block = Int(t / 600) % 3
            let (f, amp, n) = block == 0 ? (0.0, 0.0, 0.006) : block == 1 ? (1.85, 0.32, 0.02) : (2.75, 0.95, 0.03)
            let s = f > 0 ? sin(2 * .pi * f * t) + 0.35 * sin(4 * .pi * f * t) : 0
            out.append(SensorSample(ts: t, values: [0.4 * amp * s + n * noise(), 0.2 * amp * s + n * noise(),
                                                    -1 + amp * s + n * noise()]))
            i += 1
            t = (first + i) / rate
        }
        return out
    }
}

final class FakeSnapshots: SnapshotSensors, @unchecked Sendable {
    let clock: FixedClock
    private(set) var captures: [Double] = []
    init(clock: FixedClock) { self.clock = clock }

    func capture(seconds: Double, rateHz: Double, sensors: Set<Sensor>) async throws -> [Sensor: [SensorSample]] {
        captures.append(seconds)
        let t0 = clock.now.timeIntervalSince1970
        clock.advance(by: seconds)          // a capture takes real time
        let n = Int(seconds * rateHz)
        var out: [Sensor: [SensorSample]] = [:]
        for s in sensors {
            out[s] = (0..<n).map { i in
                let t = t0 + Double(i) / rateHz
                switch s {
                case .baro: return SensorSample(ts: t, values: [101.3 - 0.0001 * Double(i)])
                case .compass: return SensorSample(ts: t, values: [90 + Double(i % 10)])
                default: return SensorSample(ts: t, values: [0.01 * Double(i % 7), 0, -0.02])
                }
            }
        }
        return out
    }
}

struct FakeBattery: BatteryState { var level = 0.8; var isLowPowerMode = false }

/// Delivers files to a phone-side handler immediately; the handler returns the ack.
final class FakeTransport: WatchFileTransport, @unchecked Sendable {
    private(set) var sent: [(url: URL, metadata: [String: Any])] = []
    func send(file: URL, metadata: [String: Any]) { sent.append((file, metadata)) }
}

func tempDir(_ name: String) -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("fswatch-\(name)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

// 2026-10-24 12:00:00 UTC, hour aligned.
let t0 = 1_792_843_200.0

func makeRecorder(_ name: String, battery: FakeBattery = FakeBattery(), prefs: RecordingPreferences = .init(),
                  now: Double = t0) -> (WatchRecorder, FakeAccelRecorder, FakeSnapshots, FakeTransport, FixedClock, MemoryKeyValueStore) {
    let clock = FixedClock(Date(timeIntervalSince1970: now))
    let a = FakeAccelRecorder(), s = FakeSnapshots(clock: clock), tr = FakeTransport(), kv = MemoryKeyValueStore()
    let r = WatchRecorder(accel: a, snapshots: s, battery: battery, transport: tr, state: kv, clock: clock,
                          outboxDir: tempDir(name), prefs: prefs)
    return (r, a, s, tr, clock, kv)
}

// MARK: - Tests

@Suite struct ChunkerTests {
    @Test func splitsByMinuteAndDetectsGaps() {
        var samples = SyntheticTrace.accel(from: t0, to: t0 + 120)
        samples.removeSubrange(1000..<1100)   // 2 s hole inside the first minute... index 1000 = 20 s
        let chunks = MinuteChunker.chunks(samples, sensor: .accel, rateHz: 50)
        #expect(chunks.count == 2)
        #expect(chunks[0].minuteID == MinuteID.from(t0))
        #expect(chunks[0].samples.count == 2900 && chunks[1].samples.count == 3000)
        #expect(chunks[0].gaps == [RawGap(sampleIndex: 1000, missingCount: 100)])
        #expect(chunks[1].gaps.isEmpty)
    }

    @Test func gapSpans() {
        let s = [SensorSample(ts: 10, values: [0]), SensorSample(ts: 20, values: [0]), SensorSample(ts: 300, values: [0])]
        #expect(MinuteChunker.gapSpans(s, from: 0, to: 400) == [[20, 300], [300, 400]])
    }
}

@Suite struct ContainerTests {
    @Test func roundTrip() throws {
        var c = ChunkContainer(fileID: "f1", createdAt: t0, gaps: [[1, 2]])
        for ch in MinuteChunker.chunks(SyntheticTrace.accel(from: t0, to: t0 + 180), sensor: .accel, rateHz: 50) {
            try c.append(ch, tier: 1)
        }
        let back = try ChunkContainer.decode(c.encoded())
        #expect(back == c)
        #expect(back.minuteRange == MinuteID.from(t0)...MinuteID.from(t0) + 2)
        let decoded = try RawCodec.decode(back.payloads[1])
        #expect(decoded.minuteID == MinuteID.from(t0) + 1 && decoded.samples.count == 3000)
        #expect(c.transferMetadata["minute_from"] as? Int64 == MinuteID.from(t0))
        #expect(c.transferMetadata["encoding"] as? String == "fsr1-i16-delta-deflate")
    }
}

@Suite struct WatchRecorderTests {
    @Test func rearmsOnEveryWakeAndHarvestsFromWatermark() async throws {
        let (r, a, _, tr, clock, kv) = makeRecorder("rearm", now: t0 + 3600 * 2 + 300)
        await r.update(prefs: { var p = RecordingPreferences(); p.gyroscope = false; p.barometer = false; p.compass = false; return p }())
        kv.set(t0, "last_harvested")          // last harvest ~2 h ago
        let rep1 = await r.wake(deadline: clock.now.addingTimeInterval(30))
        #expect(a.armCount == 1 && rep1.armed)
        let wm1 = await r.lastHarvested
        // Harvest stops at the last complete minute older than the lag.
        #expect(wm1 == t0 + 3600 * 2 + 180)
        clock.advance(by: 15 * 60)
        let rep2 = await r.wake(deadline: clock.now.addingTimeInterval(30))
        #expect(a.armCount == 2)
        #expect(rep2.harvestedMinutes == 15)            // only the new 15 minutes
        #expect(await r.lastHarvested == wm1! + 15 * 60)
        // Every file sent is a tier-1 accel container.
        #expect(tr.sent.allSatisfy { ($0.metadata["tiers"] as? String) == "1" })
    }

    @Test func firstWakeStartsAtRetentionLimitAndCapsHoursPerWake() async {
        let (r, _, _, _, clock, _) = makeRecorder("cap")
        let rep = await r.wake(deadline: clock.now.addingTimeInterval(60))
        #expect(rep.filesSent.count >= WatchConfig.maxHarvestHoursPerWake - 1)
        let wm = await r.lastHarvested!
        #expect(wm <= t0 - WatchConfig.recorderRetention + Double(WatchConfig.maxHarvestHoursPerWake) * 3600)
    }

    @Test func watermarkUnchangedWhenRecorderFails() async {
        let (r, a, _, _, clock, kv) = makeRecorder("fail")
        kv.set(t0 - 1800, "last_harvested")
        a.failNext = true
        _ = await r.wake(deadline: clock.now.addingTimeInterval(30))
        #expect(await r.lastHarvested == t0 - 1800)
    }

    @Test func gapsAreLoggedNotWorkedAround() async {
        let (r, a, _, tr, clock, kv) = makeRecorder("gaps")
        kv.set(t0 - 3600, "last_harvested")
        a.holes = [(t0 - 3000)...(t0 - 1200)]          // 30 min without data (e.g. watch-detected sleep)
        let rep = await r.wake(deadline: clock.now.addingTimeInterval(30))
        #expect(rep.gaps.contains { $0[0] <= t0 - 2999 && $0[1] >= t0 - 1201 })
        let c = try? ChunkContainer.decode(Data(contentsOf: tr.sent[0].url))
        #expect(c?.index.gaps.isEmpty == false)
        #expect(rep.harvestedMinutes == 60 - 2 - 30)    // lag (2 min) + hole (30 min) missing
    }

    @Test func batteryGuardSkipsTier2() async {
        for battery in [FakeBattery(level: 0.29), FakeBattery(level: 0.9, isLowPowerMode: true)] {
            let (r, _, s, _, clock, _) = makeRecorder("battery", battery: battery)
            let rep = await r.wake(deadline: clock.now.addingTimeInterval(30))
            #expect(rep.snapshot == "skipped_battery")
            #expect(s.captures.isEmpty)
        }
        let (r, _, s, _, clock, _) = makeRecorder("battery-ok", battery: FakeBattery(level: 0.30))
        #expect(await r.wake(deadline: clock.now.addingTimeInterval(30)).snapshot == "taken")
        #expect(s.captures == [5])
    }

    @Test func snapshotRespectsIntervalAndTimeBudget() async {
        var p = RecordingPreferences()
        p.accelerometer = false
        p.snapshotSeconds = 8
        let (r, _, s, tr, clock, _) = makeRecorder("budget", prefs: p)
        // 6 s left: 8 s requested → shortened to 6 − margin = 4 s.
        let rep = await r.wake(deadline: clock.now.addingTimeInterval(6))
        #expect(rep.snapshot == "taken" && rep.snapshotSeconds == 4)
        #expect(clock.now <= Date(timeIntervalSince1970: t0 + 6))
        // Not due again until the interval has passed.
        clock.advance(by: 30 * 60)
        #expect(await r.wake(deadline: clock.now.addingTimeInterval(30)).snapshot == "not_due")
        clock.advance(by: 30 * 60)
        // Due, but only 4 s of budget: 4 − 2 margin < 3 s minimum → skipped.
        #expect(await r.wake(deadline: clock.now.addingTimeInterval(4)).snapshot == "skipped_budget")
        #expect(s.captures == [4])
        let c = try? ChunkContainer.decode(Data(contentsOf: tr.sent[0].url))
        #expect(Set(c?.index.entries.map(\.sensor) ?? []) == ["gyro", "baro", "compass"])
        #expect(c?.index.entries.allSatisfy { $0.tier == 2 } == true)
    }

    @Test func outboxDeletesOnlyAfterAckAndResendsStale() async {
        let (r, _, _, tr, clock, kv) = makeRecorder("ack")
        kv.set(t0 - 7200, "last_harvested")
        let rep = await r.wake(deadline: clock.now.addingTimeInterval(30))
        #expect(rep.filesSent.count == 3)                       // 2 hourly tier-1 files + 1 snapshot
        #expect(r.outbox.pending.count == 3)
        await r.acknowledge(rep.filesSent[0])
        #expect(r.outbox.pending.count == 2)
        let before = tr.sent.count
        clock.advance(by: WatchConfig.resendAfter + 60)
        let rep2 = await r.wake(deadline: clock.now.addingTimeInterval(30))
        #expect(Set(rep2.resent) == Set(r.outbox.pending).subtracting(rep2.filesSent))
        #expect(tr.sent.count > before)
    }

    @Test func accelerometerOffMeansNoTier1() async {
        var p = RecordingPreferences(); p.accelerometer = false
        let (r, a, _, _, clock, _) = makeRecorder("off", prefs: p)
        let rep = await r.wake(deadline: clock.now.addingTimeInterval(30))
        #expect(!rep.armed && a.armCount == 0 && rep.harvestedMinutes == 0)
    }

    @Test func preferencesSanitizedAndMirrored() throws {
        var p = RecordingPreferences()
        p.snapshotIntervalMin = 45
        p.snapshotSeconds = 30
        let ctx = try p.asContext()
        let back = RecordingPreferences.from(context: ctx)!
        #expect(back.snapshotIntervalMin == 60 && back.snapshotSeconds == 10)
    }
}

@Suite struct SessionTests {
    @Test func sessionBecomesTier3ChunksPerHour() async throws {
        let s = SessionAssembler()
        await s.begin(at: t0 - 600)
        await s.add(.accel, SyntheticTrace.accel(from: t0 - 600, to: t0 + 600))
        await s.add(.hrSession, stride(from: t0 - 600, to: t0 + 600, by: 5).map { SensorSample(ts: $0, values: [120]) })
        let hours = await s.finish()
        #expect(hours.count == 2)                                  // crosses the hour boundary
        #expect(hours.flatMap { $0 }.filter { $0.sensor == .accel }.count == 20)
        #expect(hours[0].first { $0.sensor == .hrSession }?.samples.count == 12)
    }
}

/// Phase 3 gate: compression ratio on realistic synthetic 50 Hz traces.
@Suite struct CompressionRatioTests {
    @Test func syntheticAccelRatio() throws {
        var raw = 0, packed = 0, compressed = 0
        for ch in MinuteChunker.chunks(SyntheticTrace.accel(from: t0, to: t0 + 1800), sensor: .accel, rateHz: 50) {
            raw += ch.samples.count * 3 * 4             // float32 x/y/z, the naive format
            packed += RawCodec.pack(ch).count
            compressed += try RawCodec.encode(ch).count
        }
        let ratio = Double(raw) / Double(compressed)
        print(String(format: "METRIC accel_compression float32_bytes=%d fsr1_bytes=%d deflate_bytes=%d ratio_vs_float32=%.2f ratio_vs_int16=%.2f",
                     raw, packed, compressed, ratio, Double(packed) / Double(compressed)))
        #expect(ratio > 2.5)
    }
}
