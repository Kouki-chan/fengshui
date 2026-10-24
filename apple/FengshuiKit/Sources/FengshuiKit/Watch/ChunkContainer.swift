import Foundation

/// One transfer file = up to an hour of per-minute chunks (spec §7.4).
///
/// Layout: magic 'FSC1' | u32 LE index length | JSON index | concatenated payloads.
/// Each index entry says where its (already compressed, `fsr1`) payload sits.
public struct ChunkContainer: Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var minuteID: Int64
        public var sensor: String
        public var tier: Int
        public var rateHz: Double
        public var sampleCount: Int
        public var axes: Int
        public var scale: Double
        public var offset: Double
        public var encoding: String
        public var byteOffset: Int
        public var byteLength: Int

        enum CodingKeys: String, CodingKey {
            case minuteID = "minute_id", sensor, tier, rateHz = "rate_hz", sampleCount = "sample_count", axes, scale,
                 offset, encoding, byteOffset = "byte_offset", byteLength = "byte_length"
        }
    }

    public struct Index: Codable, Equatable, Sendable {
        public var fileID: String
        public var createdAt: Double
        public var entries: [Entry]
        /// Spans with no CMSensorRecorder data (logged for the device test, spec §7.1).
        public var gaps: [[Double]]

        enum CodingKeys: String, CodingKey { case fileID = "file_id", createdAt = "created_at", entries, gaps }
    }

    public var index: Index
    public var payloads: [Data]

    static let magic = Array("FSC1".utf8)

    public init(fileID: String, createdAt: Double, gaps: [[Double]] = []) {
        index = Index(fileID: fileID, createdAt: createdAt, entries: [], gaps: gaps)
        payloads = []
    }

    public mutating func append(_ chunk: RawChunk, tier: Int) throws {
        let payload = try RawCodec.encode(chunk)
        let offset = payloads.reduce(0) { $0 + $1.count }
        index.entries.append(Entry(minuteID: chunk.minuteID, sensor: chunk.sensor.rawValue, tier: tier,
                                   rateHz: Double(chunk.rateHz), sampleCount: chunk.samples.count,
                                   axes: chunk.sensor.axes, scale: chunk.sensor.scale, offset: chunk.sensor.offset,
                                   encoding: RawCodec.encoding, byteOffset: offset, byteLength: payload.count))
        payloads.append(payload)
    }

    public var minuteRange: ClosedRange<Int64>? {
        guard let lo = index.entries.map(\.minuteID).min(), let hi = index.entries.map(\.minuteID).max() else { return nil }
        return lo...hi
    }

    public func encoded() throws -> Data {
        let json = try JSONEncoder.sortedKeys.encode(index)
        var out = Data(Self.magic)
        out.appendLE(UInt32(json.count))
        out.append(json)
        for p in payloads { out.append(p) }
        return out
    }

    public static func decode(_ data: Data) throws -> ChunkContainer {
        let b = [UInt8](data)
        guard b.count >= 8, Array(b[0..<4]) == magic else { throw RawCodecError.badMagic }
        var r = ByteReader(bytes: b, pos: 4)
        let n = Int(r.u32())
        guard b.count >= 8 + n else { throw RawCodecError.truncated }
        let index = try JSONDecoder().decode(Index.self, from: Data(b[8..<(8 + n)]))
        let base = 8 + n
        var payloads: [Data] = []
        for e in index.entries {
            let lo = base + e.byteOffset, hi = lo + e.byteLength
            guard hi <= b.count else { throw RawCodecError.truncated }
            payloads.append(Data(b[lo..<hi]))
        }
        var c = ChunkContainer(fileID: index.fileID, createdAt: index.createdAt, gaps: index.gaps)
        c.index = index
        c.payloads = payloads
        return c
    }

    /// Transfer metadata (spec §7.4: sensor, tier, minute range, encoding).
    public var transferMetadata: [String: Any] {
        [
            "file_id": index.fileID,
            "sensors": Array(Set(index.entries.map(\.sensor))).sorted().joined(separator: ","),
            "tiers": Array(Set(index.entries.map(\.tier))).sorted().map(String.init).joined(separator: ","),
            "minute_from": minuteRange?.lowerBound ?? 0,
            "minute_to": minuteRange?.upperBound ?? 0,
            "encoding": RawCodec.encoding,
            "format": "FSC1",
        ]
    }
}
