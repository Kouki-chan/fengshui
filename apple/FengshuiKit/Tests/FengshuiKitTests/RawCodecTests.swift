import Foundation
import Testing
@testable import FengshuiKit

/// Shared vectors written by engine/tests/make_raw_vectors.py.
struct Vector: Decodable {
    let name: String
    let sensor: String
    let start_ts: Double
    let rate_hz: Float
    let gaps: [[UInt32]]
    let samples: [[Int16]]

    var chunk: RawChunk {
        RawChunk(sensor: Sensor(rawValue: sensor)!, startTS: start_ts, rateHz: rate_hz, samples: samples,
                 gaps: gaps.map { RawGap(sampleIndex: $0[0], missingCount: $0[1]) })
    }
}

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let rawDir = repoRoot.appendingPathComponent("fixtures/raw")

func loadVectors() throws -> [Vector] {
    try JSONDecoder().decode([Vector].self, from: Data(contentsOf: rawDir.appendingPathComponent("vectors.json")))
}

@Suite struct RawCodecTests {
    @Test func packMatchesPythonBytes() throws {
        for v in try loadVectors() {
            let expected = try Data(contentsOf: rawDir.appendingPathComponent("\(v.name).fsr1"))
            #expect(RawCodec.pack(v.chunk) == expected, "\(v.name)")
        }
    }

    @Test func roundTrip() throws {
        for v in try loadVectors() {
            #expect(try RawCodec.decode(RawCodec.encode(v.chunk)) == v.chunk, "\(v.name)")
        }
    }

    @Test func decodesPythonCompressed() throws {
        for v in try loadVectors() {
            let data = try Data(contentsOf: rawDir.appendingPathComponent("py/\(v.name).bin"))
            #expect(try RawCodec.decode(data) == v.chunk, "\(v.name)")
        }
    }

    /// Writes Apple-compressed fixtures for the Python cross-check (deterministic output).
    @Test func writeSwiftFixtures() throws {
        let dir = rawDir.appendingPathComponent("swift")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for v in try loadVectors() {
            let url = dir.appendingPathComponent("\(v.name).bin")
            let data = try RawCodec.encode(v.chunk)
            if (try? Data(contentsOf: url)) != data { try data.write(to: url) }
        }
    }

    @Test func wrappingDeltas() throws {
        let c = RawChunk(sensor: .accel, startTS: 0, rateHz: 50,
                         samples: [[32767, -32768, 0], [-32768, 32767, 1], [32767, 0, -32768]])
        #expect(try RawCodec.decode(RawCodec.encode(c)) == c)
    }

    @Test func quantize() {
        #expect(RawCodec.quantize(.accel, 0.5 / 2048) == 1)
        #expect(RawCodec.quantize(.accel, -0.5 / 2048) == -1)
        #expect(RawCodec.quantize(.accel, 100) == 32767)
        #expect(RawCodec.quantize(.baro, 101.3255) == 1326)
    }

    @Test func rejectsGarbage() {
        #expect(throws: RawCodecError.badMagic) { try RawCodec.unpack(Data("XXXX".utf8) + Data(count: 30)) }
        #expect(throws: RawCodecError.truncated) { try RawCodec.unpack(Data(count: 4)) }
    }
}

@Suite struct MinuteIDTests {
    @Test func values() {
        #expect(MinuteID.from(0.0) == 0)
        #expect(MinuteID.from(59.999) == 0)
        #expect(MinuteID.from(60.0) == 1)
        #expect(MinuteID.from(-0.5) == -1)
        #expect(MinuteID.from(1792843215.0) == 29880720)
    }
}

@Suite struct SchemaTests {
    @Test func bundledSchemaMatchesEngineFile() throws {
        let engine = try String(contentsOf: repoRoot.appendingPathComponent("engine/fengshui_engine/schema_v1.sql"),
                                encoding: .utf8)
        #expect(try Schema.sql() == engine)
    }
}

@Suite struct ExportKeyTests {
    /// Vectors shared with scripts/tests (fixtures/export_keys.json).
    @Test func matchesPython() throws {
        struct K: Decodable {
            let hk_type: String; let start: Double; let end: Double
            let source_name: String?; let value: Double?; let value_text: String?; let key: String
        }
        let url = repoRoot.appendingPathComponent("fixtures/export_keys.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        for k in try JSONDecoder().decode([K].self, from: Data(contentsOf: url)) {
            #expect(ExportKey.make(hkType: k.hk_type, start: k.start, end: k.end, sourceName: k.source_name,
                                   value: k.value, valueText: k.value_text) == k.key)
        }
    }
}
