import Compression
import Foundation

/// Sensors recorded by the watch, with the quantization from spec §7.3.
public enum Sensor: String, CaseIterable, Codable, Sendable {
    case accel, gyro, baro, compass, hrSession = "hr_session"

    public var code: UInt8 {
        switch self {
        case .accel: 1
        case .gyro: 2
        case .baro: 3
        case .compass: 4
        case .hrSession: 5
        }
    }

    public init?(code: UInt8) {
        guard let s = Sensor.allCases.first(where: { $0.code == code }) else { return nil }
        self = s
    }

    public var axes: Int { (self == .accel || self == .gyro) ? 3 : 1 }

    /// physical = int * scale + offset
    public var scale: Double {
        switch self {
        case .accel: 1.0 / 2048
        case .gyro: 0.001
        case .baro: 0.001
        case .compass: 0.02
        case .hrSession: 0.1
        }
    }

    public var offset: Double { self == .baro ? 100 : 0 }
}

public struct RawGap: Equatable, Codable, Sendable {
    public var sampleIndex: UInt32
    public var missingCount: UInt32
    public init(sampleIndex: UInt32, missingCount: UInt32) {
        self.sampleIndex = sampleIndex
        self.missingCount = missingCount
    }
}

/// One sensor, one minute, quantized.
public struct RawChunk: Equatable, Sendable {
    public var sensor: Sensor
    public var startTS: Double
    public var rateHz: Float
    /// Row-major: samples[i] has `sensor.axes` values.
    public var samples: [[Int16]]
    public var gaps: [RawGap]

    public init(sensor: Sensor, startTS: Double, rateHz: Float, samples: [[Int16]], gaps: [RawGap] = []) {
        self.sensor = sensor
        self.startTS = startTS
        self.rateHz = rateHz
        self.samples = samples
        self.gaps = gaps
    }

    public var minuteID: Int64 { MinuteID.from(startTS) }
}

public enum RawCodecError: Error, Equatable {
    case badMagic, unsupportedVersion(UInt8), unknownSensor(UInt8), badAxes, truncated, compressionFailed
}

/// `fsr1-i16-delta-deflate`. Compression uses Apple's COMPRESSION_ZLIB, which is
/// raw DEFLATE without a zlib header (Python decodes with wbits = -15).
public enum RawCodec {
    public static let encoding = "fsr1-i16-delta-deflate"
    static let magic: [UInt8] = Array("FSR1".utf8)
    static let version: UInt8 = 1
    static let headerSize = 4 + 4 + 8 + 4 + 4 + 2

    /// Physical → int16, rounding half away from zero and clamping.
    public static func quantize(_ sensor: Sensor, _ value: Double) -> Int16 {
        Int16(clamping: Int(((value - sensor.offset) / sensor.scale).rounded(.toNearestOrAwayFromZero)))
    }

    public static func physical(_ sensor: Sensor, _ value: Int16) -> Double {
        Double(value) * sensor.scale + sensor.offset
    }

    // MARK: Packing (uncompressed)

    public static func pack(_ chunk: RawChunk) -> Data {
        var out = Data(capacity: headerSize + chunk.gaps.count * 8 + chunk.samples.count * chunk.sensor.axes * 2)
        out.append(contentsOf: magic)
        out.append(version)
        out.append(chunk.sensor.code)
        out.append(UInt8(chunk.sensor.axes))
        out.append(0)
        out.appendLE(chunk.startTS.bitPattern)
        out.appendLE(chunk.rateHz.bitPattern)
        out.appendLE(UInt32(chunk.samples.count))
        out.appendLE(UInt16(chunk.gaps.count))
        for g in chunk.gaps {
            out.appendLE(g.sampleIndex)
            out.appendLE(g.missingCount)
        }
        guard let first = chunk.samples.first else { return out }
        for v in first { out.appendLE(UInt16(bitPattern: v)) }
        var prev = first
        for row in chunk.samples.dropFirst() {
            for a in 0..<row.count {
                // Wrapping subtraction keeps the round trip lossless at int16 extremes.
                out.appendLE(UInt16(bitPattern: row[a] &- prev[a]))
            }
            prev = row
        }
        return out
    }

    public static func unpack(_ data: Data) throws -> RawChunk {
        let b = [UInt8](data)
        guard b.count >= headerSize else { throw RawCodecError.truncated }
        guard Array(b[0..<4]) == magic else { throw RawCodecError.badMagic }
        guard b[4] == version else { throw RawCodecError.unsupportedVersion(b[4]) }
        guard let sensor = Sensor(code: b[5]) else { throw RawCodecError.unknownSensor(b[5]) }
        let axes = Int(b[6])
        guard axes == sensor.axes else { throw RawCodecError.badAxes }
        var r = ByteReader(bytes: b, pos: 8)
        let start = Double(bitPattern: r.u64())
        let rate = Float(bitPattern: r.u32())
        let n = Int(r.u32())
        let nGaps = Int(r.u16())
        guard b.count == headerSize + nGaps * 8 + n * axes * 2 else { throw RawCodecError.truncated }
        var gaps: [RawGap] = []
        for _ in 0..<nGaps { gaps.append(RawGap(sampleIndex: r.u32(), missingCount: r.u32())) }
        var samples: [[Int16]] = []
        samples.reserveCapacity(n)
        if n > 0 {
            var prev = (0..<axes).map { _ in Int16(bitPattern: r.u16()) }
            samples.append(prev)
            for _ in 1..<n {
                prev = prev.map { $0 &+ Int16(bitPattern: r.u16()) }
                samples.append(prev)
            }
        }
        return RawChunk(sensor: sensor, startTS: start, rateHz: rate, samples: samples, gaps: gaps)
    }

    // MARK: Compressed

    public static func encode(_ chunk: RawChunk) throws -> Data {
        try deflate(pack(chunk))
    }

    public static func decode(_ payload: Data) throws -> RawChunk {
        try unpack(inflate(payload))
    }

    public static func deflate(_ input: Data) throws -> Data {
        // Raw DEFLATE can expand tiny inputs slightly; leave headroom.
        let capacity = input.count + input.count / 8 + 64
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(bitPattern: 1)!,
                                          input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 || input.isEmpty else { throw RawCodecError.compressionFailed }
        out.count = written
        return out
    }

    public static func inflate(_ input: Data) throws -> Data {
        // Chunks are at most a few hundred KB; grow the buffer until it fits.
        var capacity = max(input.count * 8, 4096)
        while capacity <= 64 << 20 {
            var out = Data(count: capacity)
            let n = out.withUnsafeMutableBytes { dst in
                input.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            if n > 0 && n < capacity {
                out.count = n
                return out
            }
            capacity *= 4
        }
        throw RawCodecError.compressionFailed
    }
}

// MARK: - Little-endian helpers

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}

struct ByteReader {
    let bytes: [UInt8]
    var pos: Int

    mutating func read<T: FixedWidthInteger>(_: T.Type) -> T {
        var v: T = 0
        for i in 0..<MemoryLayout<T>.size { v |= T(bytes[pos + i]) << (8 * i) }
        pos += MemoryLayout<T>.size
        return v
    }

    mutating func u16() -> UInt16 { read(UInt16.self) }
    mutating func u32() -> UInt32 { read(UInt32.self) }
    mutating func u64() -> UInt64 { read(UInt64.self) }
}
