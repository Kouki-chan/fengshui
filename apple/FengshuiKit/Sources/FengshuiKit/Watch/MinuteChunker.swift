import Foundation

/// A timestamped physical sample (seconds since 1970, values in sensor units).
public struct SensorSample: Sendable, Equatable {
    public var ts: Double
    public var values: [Double]
    public init(ts: Double, values: [Double]) { self.ts = ts; self.values = values }
}

/// Splits a stream of samples into one `RawChunk` per minute (spec §7.3/7.4).
/// Within a minute, samples are assumed uniform at `rateHz`; holes longer than
/// `gapFactor` sample periods are recorded as gaps (index, missing count).
public enum MinuteChunker {
    public static let gapFactor = 1.5

    public static func chunks(_ samples: [SensorSample], sensor: Sensor, rateHz: Double) -> [RawChunk] {
        guard !samples.isEmpty else { return [] }
        let period = 1 / rateHz
        var out: [RawChunk] = []
        var i = 0
        let sorted = samples.sorted { $0.ts < $1.ts }
        while i < sorted.count {
            let mid = MinuteID.from(sorted[i].ts)
            var rows: [[Int16]] = []
            var gaps: [RawGap] = []
            var prev: Double?
            let start = sorted[i].ts
            while i < sorted.count, MinuteID.from(sorted[i].ts) == mid {
                let s = sorted[i]
                if let p = prev, s.ts - p > gapFactor * period {
                    let missing = UInt32(((s.ts - p) / period).rounded()) - 1
                    if missing > 0 { gaps.append(RawGap(sampleIndex: UInt32(rows.count), missingCount: missing)) }
                }
                rows.append(s.values.map { RawCodec.quantize(sensor, $0) })
                prev = s.ts
                i += 1
            }
            out.append(RawChunk(sensor: sensor, startTS: start, rateHz: Float(rateHz), samples: rows, gaps: gaps))
        }
        return out
    }

    /// Spans longer than `minGap` seconds without any sample, between `from` and `to`
    /// (e.g. CMSensorRecorder pauses during watch-detected sleep, spec §7.1).
    public static func gapSpans(_ samples: [SensorSample], from: Double, to: Double, minGap: Double = 60) -> [[Double]] {
        var spans: [[Double]] = []
        var last = from
        for s in samples.sorted(by: { $0.ts < $1.ts }) {
            if s.ts - last > minGap { spans.append([last, s.ts]) }
            last = max(last, s.ts)
        }
        if to - last > minGap { spans.append([last, to]) }
        return spans
    }
}
