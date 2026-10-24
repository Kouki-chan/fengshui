import Foundation

// MARK: - Dependencies (real ones live in the watch target, fakes in tests)

/// Tier 1: CMSensorRecorder (spec §7.1).
public protocol AccelerometerRecorder: Sendable {
    var isAvailable: Bool { get }
    /// recordAccelerometer(forDuration:) — re-armed on every wake.
    func arm(duration: TimeInterval)
    /// Recorded samples in g, [from, to).
    func samples(from: Double, to: Double) async throws -> [SensorSample]
}

/// Tier 2: a short burst of gyro / barometer / compass.
public protocol SnapshotSensors: Sendable {
    func capture(seconds: Double, rateHz: Double, sensors: Set<Sensor>) async throws -> [Sensor: [SensorSample]]
}

public protocol BatteryState: Sendable {
    var level: Double { get }          // 0…1
    var isLowPowerMode: Bool { get }
}

/// Watch → phone file channel (WCSession.transferFile in production).
public protocol WatchFileTransport: Sendable {
    func send(file: URL, metadata: [String: Any])
}

/// Small persistent state (UserDefaults on the watch).
public protocol KeyValueStore: Sendable {
    func double(_ key: String) -> Double?
    func set(_ value: Double, _ key: String)
    func string(_ key: String) -> String?
    func set(_ value: String, _ key: String)
}

public final class MemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var d: [String: Any] = [:]
    public init() {}
    public func double(_ key: String) -> Double? { lock.withLock { d[key] as? Double } }
    public func set(_ value: Double, _ key: String) { lock.withLock { d[key] = value } }
    public func string(_ key: String) -> String? { lock.withLock { d[key] as? String } }
    public func set(_ value: String, _ key: String) { lock.withLock { d[key] = value } }
}

// MARK: - Configuration

/// Watch-side tunables (the engine's live in fengshui_engine/config.py).
public enum WatchConfig {
    public static let accelRateHz = 50.0
    public static let snapshotRateHz = 25.0
    public static let armDuration: TimeInterval = 12 * 3600
    /// watchOS keeps CMSensorRecorder data for about 3 days.
    public static let recorderRetention: TimeInterval = 3 * 86400
    /// Recorder data shows up with a delay; only harvest complete minutes older than this.
    public static let harvestLag: TimeInterval = 120
    /// Hours of tier-1 data processed per wake (keeps each wake inside its budget).
    public static let maxHarvestHoursPerWake = 6
    public static let batteryMinimum = 0.30
    /// Seconds kept free at the end of a background task for saving state and scheduling.
    public static let budgetMargin: TimeInterval = 2.0
    public static let minSnapshotSeconds = 3.0
    /// A sent file without acknowledgment is re-sent after this long.
    public static let resendAfter: TimeInterval = 6 * 3600
}

// MARK: - Coordinator

/// Everything the watch does on a wake (spec §7.1, §7.4), independent of watchOS APIs.
public actor WatchRecorder {
    public struct Report: Sendable, Equatable {
        public var armed = false
        public var harvestedMinutes = 0
        public var filesSent: [String] = []
        public var resent: [String] = []
        public var snapshot: String = "not_due"      // taken | not_due | skipped_battery | skipped_budget | disabled
        public var snapshotSeconds: Double = 0
        public var gaps: [[Double]] = []
    }

    private let accel: AccelerometerRecorder
    private let snapshots: SnapshotSensors
    private let battery: BatteryState
    private let transport: WatchFileTransport
    private let state: KeyValueStore
    private let clock: Clock
    public nonisolated let outbox: Outbox
    public private(set) var prefs: RecordingPreferences

    public init(accel: AccelerometerRecorder, snapshots: SnapshotSensors, battery: BatteryState,
                transport: WatchFileTransport, state: KeyValueStore, clock: Clock, outboxDir: URL,
                prefs: RecordingPreferences = RecordingPreferences()) {
        self.accel = accel
        self.snapshots = snapshots
        self.battery = battery
        self.transport = transport
        self.state = state
        self.clock = clock
        self.prefs = prefs.sanitized()
        outbox = Outbox(dir: outboxDir, state: state)
    }

    public func update(prefs: RecordingPreferences) { self.prefs = prefs.sanitized() }

    public var lastHarvested: Double? { state.double("last_harvested") }
    public var lastSnapshot: Double? { state.double("last_snapshot") }

    /// One background wake. `deadline` = when the system expects the task to finish.
    public func wake(deadline: Date) async -> Report {
        var r = Report()
        let now = clock.now.timeIntervalSince1970

        // Tier 1: keep the recorder armed (re-armed on every wake).
        if prefs.accelerometer, accel.isAvailable {
            accel.arm(duration: WatchConfig.armDuration)
            state.set(now, "armed_at")
            r.armed = true
            await harvest(now: now, deadline: deadline, report: &r)
        }

        // Tier 2: snapshot when due, battery allows, and the budget has room.
        await snapshotIfDue(now: now, deadline: deadline, report: &r)

        // Re-send anything the phone never acknowledged.
        for f in outbox.unacknowledged(olderThan: clock.now.timeIntervalSince1970 - WatchConfig.resendAfter) {
            transport.send(file: f.url, metadata: f.metadata)
            outbox.markSent(f.id, at: clock.now.timeIntervalSince1970)
            r.resent.append(f.id)
        }
        return r
    }

    private func harvest(now: Double, deadline: Date, report r: inout Report) async {
        // Complete minutes only, not older than the recorder keeps.
        let lagged = now - WatchConfig.harvestLag
        let end = lagged - lagged.truncatingRemainder(dividingBy: 60)
        var from = max(lastHarvested ?? (now - WatchConfig.recorderRetention), now - WatchConfig.recorderRetention)
        from -= from.truncatingRemainder(dividingBy: 60)
        var hours = 0
        while from < end, hours < WatchConfig.maxHarvestHoursPerWake,
              clock.now.addingTimeInterval(WatchConfig.budgetMargin) < deadline {
            let hourEnd = min(end, (from / 3600).rounded(.down) * 3600 + 3600)
            do {
                let samples = try await accel.samples(from: from, to: hourEnd)
                let gaps = MinuteChunker.gapSpans(samples, from: from, to: hourEnd)
                r.gaps += gaps
                let chunks = MinuteChunker.chunks(samples, sensor: .accel, rateHz: WatchConfig.accelRateHz)
                if !chunks.isEmpty {
                    let id = try send(chunks, tier: 1, gaps: gaps)
                    r.filesSent.append(id)
                    r.harvestedMinutes += chunks.count
                }
                // Advance even for an empty hour (watch off / recorder paused): the gap is logged.
                state.set(hourEnd, "last_harvested")
                from = hourEnd
                hours += 1
            } catch {
                break   // retried on the next wake from the same watermark
            }
        }
    }

    private func snapshotIfDue(now: Double, deadline: Date, report r: inout Report) async {
        guard prefs.snapshotSensorsEnabled else { r.snapshot = "disabled"; return }
        let interval = Double(prefs.snapshotIntervalMin) * 60
        // 1-minute slack so a refresh scheduled for "interval" isn't skipped for being a few seconds early.
        if let last = lastSnapshot, now - last < interval - 60 { r.snapshot = "not_due"; return }
        if battery.level < WatchConfig.batteryMinimum || battery.isLowPowerMode {
            r.snapshot = "skipped_battery"; return
        }
        let remaining = deadline.timeIntervalSince(clock.now) - WatchConfig.budgetMargin
        let seconds = min(prefs.snapshotSeconds, remaining)
        guard seconds >= WatchConfig.minSnapshotSeconds else { r.snapshot = "skipped_budget"; return }
        var sensors: Set<Sensor> = []
        if prefs.gyroscope { sensors.insert(.gyro) }
        if prefs.barometer { sensors.insert(.baro) }
        if prefs.compass { sensors.insert(.compass) }
        do {
            let data = try await snapshots.capture(seconds: seconds, rateHz: WatchConfig.snapshotRateHz, sensors: sensors)
            var chunks: [RawChunk] = []
            for s in Sensor.allCases { if let d = data[s] {
                chunks += MinuteChunker.chunks(d, sensor: s, rateHz: WatchConfig.snapshotRateHz)
            } }
            if !chunks.isEmpty { r.filesSent.append(try send(chunks, tier: 2, gaps: [])) }
            state.set(now, "last_snapshot")
            r.snapshot = "taken"
            r.snapshotSeconds = seconds
        } catch {
            r.snapshot = "skipped_error"
        }
    }

    /// Writes a container to the outbox and hands it to the transport.
    public func send(_ chunks: [RawChunk], tier: Int, gaps: [[Double]]) throws -> String {
        let id = UUID().uuidString
        var c = ChunkContainer(fileID: id, createdAt: clock.now.timeIntervalSince1970, gaps: gaps)
        for ch in chunks { try c.append(ch, tier: tier) }
        let url = try outbox.write(c)
        transport.send(file: url, metadata: c.transferMetadata)
        outbox.markSent(id, at: clock.now.timeIntervalSince1970)
        return id
    }

    /// Phone acknowledged a file (via transferUserInfo): delete it.
    public func acknowledge(_ fileID: String) { outbox.remove(fileID) }
}

/// Files waiting for the phone's acknowledgment. Deleted only after the ack (spec §7.4).
public final class Outbox: @unchecked Sendable {
    public struct Item { public let id: String; public let url: URL; public let metadata: [String: Any] }
    public let dir: URL
    private let state: KeyValueStore
    private let lock = NSLock()

    init(dir: URL, state: KeyValueStore) {
        self.dir = dir
        self.state = state
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func write(_ c: ChunkContainer) throws -> URL {
        let url = dir.appendingPathComponent("\(c.index.fileID).fsc")
        try c.encoded().write(to: url, options: .atomic)
        return url
    }

    func markSent(_ id: String, at ts: Double) { state.set(ts, "sent:\(id)") }

    public var pending: [String] {
        lock.withLock {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasSuffix(".fsc") }.map { String($0.dropLast(4)) }.sorted()
        }
    }

    func unacknowledged(olderThan cutoff: Double) -> [Item] {
        pending.compactMap { id in
            guard let sent = state.double("sent:\(id)"), sent < cutoff else { return nil }
            let url = dir.appendingPathComponent("\(id).fsc")
            guard let c = try? ChunkContainer.decode(Data(contentsOf: url)) else { return nil }
            return Item(id: id, url: url, metadata: c.transferMetadata)
        }
    }

    func remove(_ id: String) {
        lock.withLock { try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).fsc")) }
    }
}
