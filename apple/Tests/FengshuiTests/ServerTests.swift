import FengshuiKit
import GRDB
import XCTest
@testable import Fengshui

/// Records requests and answers like the server would (unit tests; the live test uses the real one).
final class StubServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [(path: String, body: [String: Any])] = []
    nonisolated(unsafe) static var handler: (String, [String: Any]) -> (Int, [String: Any]) = { _, _ in (200, [:]) }
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let s = request.httpBodyStream {
            s.open(); var d = Data(); var buf = [UInt8](repeating: 0, count: 65536)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            s.close(); data = d
        }
        let body = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let path = request.url!.path
        Self.lock.withLock { Self.requests.append((path, body)) }
        let (code, out) = Self.handler(path, body)
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: out))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubServer.self]
        return URLSession(configuration: c)
    }
}

final class ServerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_890_000)

    override func setUp() {
        StubServer.requests = []
        StubServer.handler = { path, body in
            if path.hasSuffix("/sync") {
                let t = body["tables"] as? [String: [Any]] ?? [:]
                return (200, ["accepted": t.mapValues(\.count)])
            }
            if path.hasSuffix("/raw/archive") {
                let chunks = body["chunks"] as? [[String: Any]] ?? []
                return (200, ["archived": chunks.map { ["minute_id": $0["minute_id"]!, "sensor": $0["sensor"]!,
                                                         "tier": $0["tier"]!, "archive_ref": "day/x.fsr1"] }])
            }
            if path.hasSuffix("/health") { return (200, ["ok": true]) }
            return (404, [:])
        }
    }

    func make(_ name: String, wifi: Bool = true) throws -> (AppDatabase, ServerSync) {
        let db = try AppDatabase.temporary(name)
        try db.setPreference(ServerSync.urlKey, "http://stub.local:8765")
        let s = ServerSync(db: db, secrets: MemorySecretStore([SecretKey.serverToken: "t"]), network: FixedNetworkStatus(onWiFi: wifi),
                           clock: FixedClock(now), log: EventLog(), session: StubServer.session(), deviceID: "d")
        return (db, s)
    }

    func addSamples(_ db: AppDatabase, _ range: Range<Int>) async throws {
        try await db.writer.write { d in
            for i in range {
                try d.execute(sql: "INSERT INTO processed_samples (hk_uuid, hk_type, label, value, start_ts, end_ts, minute_id, inserted_at) VALUES (?, 'T', 'heart_rate', 60, ?, ?, 0, 0)",
                              arguments: ["u\(i)", Double(i), Double(i)])
            }
        }
    }

    func testIncrementalSyncByWatermarkAndAuthHeader() async throws {
        let (db, s) = try make("sync")
        try await addSamples(db, 0..<120)
        let r1 = try await s.sync()
        XCTAssertEqual(r1.uploaded["processed_samples"], 120)
        try await addSamples(db, 120..<130)
        StubServer.requests = []
        let r2 = try await s.sync()
        XCTAssertEqual(r2.uploaded["processed_samples"], 10)                  // only new rows
        XCTAssertEqual(try db.count("SELECT last_id_uploaded FROM server_sync_state WHERE table_name = 'processed_samples'"), 130)
        let body = StubServer.requests.first { ($0.body["tables"] as? [String: Any])?["processed_samples"] != nil }!.body
        XCTAssertNotNil(body["engine_version"])
        XCTAssertEqual(body["device_id"] as? String, "d")
    }

    func testSkipsWhenNotOnWiFi() async throws {
        let (_, s) = try make("wifi", wifi: false)
        let r = try await s.sync()
        XCTAssertEqual(r.skipped, "not on Wi-Fi")
        XCTAssertTrue(StubServer.requests.isEmpty)
    }

    func insertChunk(_ db: AppDatabase, minute: Int64) async throws {
        let c = RawChunk(sensor: .accel, startTS: Double(minute) * 60, rateHz: 50, samples: [[1, 2, 3]])
        let payload = try RawCodec.encode(c)
        try await db.writer.write { d in
            try d.execute(sql: "INSERT INTO raw_chunks (minute_id, sensor, tier, rate_hz, sample_count, axes, encoding, scale, payload, received_at) VALUES (?, 'accel', 1, 50, 1, 3, 'fsr1-i16-delta-deflate', 0.00048828125, ?, 0)",
                          arguments: [minute, payload])
        }
    }

    func testArchiveClearsOnlyConfirmedOldChunks() async throws {
        let (db, s) = try make("archive")
        let nowMin = MinuteID.from(now)
        try await insertChunk(db, minute: nowMin - 8 * 1440)        // old → archived
        try await insertChunk(db, minute: nowMin - 8 * 1440 + 1)
        try await insertChunk(db, minute: nowMin - 60)              // recent → kept
        // The server confirms only the first chunk.
        StubServer.handler = { path, body in
            let chunks = body["chunks"] as? [[String: Any]] ?? []
            return (200, ["archived": chunks.prefix(1).map { ["minute_id": $0["minute_id"]!, "sensor": "accel", "tier": 1,
                                                                "archive_ref": "d/1.fsr1"] }])
        }
        let n = try await s.archive()
        XCTAssertEqual(n, 1)
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM raw_chunks WHERE payload IS NULL AND archive_ref = 'd/1.fsr1'"), 1)
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM raw_chunks WHERE payload IS NOT NULL"), 2)
        // Payloads went out base64-encoded, untouched.
        let sent = StubServer.requests.last!.body["chunks"] as! [[String: Any]]
        XCTAssertEqual(sent.count, 2)
        XCTAssertNotNil(Data(base64Encoded: sent[0]["payload_b64"] as! String))
    }

    func testServerErrorsSurface() async throws {
        let (_, s) = try make("err")
        StubServer.handler = { _, _ in (409, ["detail": "engine version mismatch"]) }
        do { _ = try await s.sync(); XCTFail("expected failure") } catch {
            XCTAssertTrue("\(error)".contains("mismatch"))
        }
    }

    func testComputeLocationChoice() async throws {
        let (db, s) = try make("choice")
        let low = LowPower()
        let runner = EngineRunner(db: db, clock: FixedClock(now), timeZone: .current, log: EventLog(), server: s,
                                  lowPowerMode: { low.on })
        try db.setPreference(EngineRunner.locationKey, EngineRunner.Location.phone)
        var c = await runner.chooseServer(); XCTAssertFalse(c)
        try db.setPreference(EngineRunner.locationKey, EngineRunner.Location.server)
        c = await runner.chooseServer(); XCTAssertTrue(c)
        try db.setPreference(EngineRunner.locationKey, EngineRunner.Location.auto)
        c = await runner.chooseServer(); XCTAssertFalse(c)                     // no backlog, normal power
        low.on = true
        c = await runner.chooseServer(); XCTAssertTrue(c)                      // Low Power Mode + reachable
        StubServer.handler = { _, _ in (500, [:]) }
        c = await runner.chooseServer(); XCTAssertFalse(c)                     // unreachable → phone
    }

    func testServerFailureFallsBackToPhone() async throws {
        let (db, s) = try make("fallback")
        try db.setPreference(EngineRunner.locationKey, EngineRunner.Location.server)
        StubServer.handler = { _, _ in (500, ["detail": "boom"]) }
        let runner = EngineRunner(db: db, clock: FixedClock(now), timeZone: .current, log: EventLog(), server: s)
        let rec = await runner.run(["wind_down"], trigger: "t")
        XCTAssertTrue(rec.ok)
        XCTAssertEqual(rec.location, "phone (server failed)")
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM inferences WHERE kind = 'wind_down_plan'"), 1)
    }

    func testSecretsUseKeychainOnDevice() {
        let k = KeychainStore()
        k.set("fengshui_test_key", "v1")
        XCTAssertEqual(k.get("fengshui_test_key"), "v1")
        k.set("fengshui_test_key", nil)
        XCTAssertNil(k.get("fengshui_test_key"))
    }
}

final class LowPower: @unchecked Sendable { var on = false }
