import Foundation

/// Tier 3 (spec §7.1): during a user-started session every sensor runs at full rate
/// plus HR every ~5 s. Samples are buffered here and, when the session ends, turned
/// into per-minute tier-3 chunks and sent in one file per hour.
public actor SessionAssembler {
    public static let rates: [Sensor: Double] = [.accel: 50, .gyro: 50, .compass: 50, .baro: 1, .hrSession: 0.2]

    private var buffers: [Sensor: [SensorSample]] = [:]
    public private(set) var startedAt: Double?

    public init() {}

    public func begin(at ts: Double) {
        buffers = [:]
        startedAt = ts
    }

    public func add(_ sensor: Sensor, _ samples: [SensorSample]) {
        buffers[sensor, default: []] += samples
    }

    public var counts: [Sensor: Int] { buffers.mapValues(\.count) }

    /// Ends the session: returns chunks grouped by hour so each becomes one transfer file.
    public func finish() -> [[RawChunk]] {
        var byHour: [Int64: [RawChunk]] = [:]
        for (sensor, samples) in buffers {
            for c in MinuteChunker.chunks(samples, sensor: sensor, rateHz: Self.rates[sensor] ?? 1) {
                byHour[c.minuteID / 60, default: []].append(c)
            }
        }
        buffers = [:]
        startedAt = nil
        return byHour.keys.sorted().map { h in
            byHour[h]!.sorted { ($0.minuteID, $0.sensor.code) < ($1.minuteID, $1.sensor.code) }
        }
    }
}
