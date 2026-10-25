import FengshuiKit
import GRDB
import XCTest
@testable import Fengshui

/// Phase 6 live integration: the simulator app syncs to, archives on, retrieves from and
/// computes on a real server running on this Mac. Run by scripts/live_server_test.sh,
/// which starts the server and passes TEST_RUNNER_FENGSHUI_LIVE_URL / _TOKEN.
final class LiveServerTests: XCTestCase {
    func testSyncArchiveRetrieveCompute() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["FENGSHUI_LIVE_URL"], let token = env["FENGSHUI_LIVE_TOKEN"] else {
            throw XCTSkip("live server not running (scripts/live_server_test.sh)")
        }
        let parity = repoRoot.appendingPathComponent("build/parity")
        let src = parity.appendingPathComponent("source.sqlite")
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID()).sqlite")
        try FileManager.default.copyItem(at: src, to: path)
        let db = try AppDatabase(path: path.path)
        try db.setPreference(ServerSync.urlKey, url)
        let args = try JSONSerialization.jsonObject(with: Data(contentsOf: parity.appendingPathComponent("args.json"))) as! [String: Any]
        let now = args["now_ts"] as! Double
        let clock = FixedClock(Date(timeIntervalSince1970: now))
        let sync = ServerSync(db: db, secrets: MemorySecretStore([SecretKey.serverToken: token]),
                              network: FixedNetworkStatus(onWiFi: true), clock: clock, log: EventLog(), deviceID: "live-test")
        let reachable = await sync.reachable()
        XCTAssertTrue(reachable)

        // 1. Sync is idempotent.
        let r1 = try await sync.sync()
        XCTAssertGreaterThan(r1.uploaded["processed_samples"] ?? 0, 10_000)
        let r2 = try await sync.sync()
        XCTAssertEqual(r2.uploaded["processed_samples"] ?? 0, 0)

        // 2. Remote compute → identical result to the Mac's local run (build/parity/mac.json).
        let n = try await sync.compute(tasks: args["tasks"] as! [String], tz: TimeZone(identifier: args["tz"] as! String)!)
        XCTAssertGreaterThan(n, 100)
        let dump = (try EmbeddedPython.shared.call("dump", ["db_path": path.path]) as! [String: Any])["canonical"] as! String
        let mac = try String(contentsOf: parity.appendingPathComponent("mac.json"), encoding: .utf8)
        XCTAssertTrue(dump == mac, "server compute result differs from the Mac/phone run")
        XCTAssertGreaterThan(try db.count("SELECT COUNT(*) FROM inferences WHERE computed_where = 'server'"), 100)

        // 3. Eight days later the raw chunks are archived; payloads cleared only after confirmation.
        let before = try await db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT minute_id, payload FROM raw_chunks WHERE sensor = 'accel' AND tier = 1 ORDER BY minute_id LIMIT 30")
                .map { ($0["minute_id"] as Int64, $0["payload"] as Data) }
        }
        clock.advance(by: 8 * 86400)
        let archived = try await sync.archive()
        XCTAssertGreaterThan(archived, 1000)
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM raw_chunks WHERE payload IS NOT NULL"), 0)

        // 4. Retrieval is byte-exact.
        let got = try await sync.retrieve(sensor: "accel", from: before.first!.0, to: before.last!.0)
        let tier1 = got.filter { $0.tier == 1 }
        XCTAssertEqual(tier1.map(\.minuteID), before.map(\.0))
        XCTAssertEqual(tier1.map(\.payload), before.map(\.1))
    }
}
