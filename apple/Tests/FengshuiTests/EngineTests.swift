import FengshuiKit
import GRDB
import XCTest
@testable import Fengshui

/// Phase 4 gate: the same scenario through embedded Python in the simulator produces
/// identical inference rows to the Mac run; features performance is recorded.
final class EngineTests: XCTestCase {
    let parity = repoRoot.appendingPathComponent("build/parity")

    func copySource(_ name: String) throws -> String {
        let src = parity.appendingPathComponent("source.sqlite")
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw XCTSkip("run engine/tests/parity.py first (scripts/test_all.sh does)")
        }
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID()).sqlite")
        try FileManager.default.copyItem(at: src, to: dst)
        return dst.path
    }

    func testEmbeddedEngineMatchesMacExactly() throws {
        let path = try copySource("parity")
        var args = try JSONSerialization.jsonObject(with: Data(contentsOf: parity.appendingPathComponent("args.json"))) as! [String: Any]
        args["db_path"] = path
        let t0 = Date()
        let summary = try EmbeddedPython.shared.call("run", args) as! [String: Any]
        let total = Date().timeIntervalSince(t0)
        let tasks = summary["tasks"] as! [String: [String: Any]]
        let feat = tasks["features"]!
        let minutes = feat["rows_written"] as! Int
        let secs = feat["seconds"] as! Double
        print(String(format: "METRIC simulator_engine_run_s=%.2f features_minutes=%d features_s=%.2f features_per_day_s=%.1f",
                     total, minutes, secs, secs / Double(minutes) * 1440))
        let phone = (try EmbeddedPython.shared.call("dump", ["db_path": path]) as! [String: Any])["canonical"] as! String
        let mac = try String(contentsOf: parity.appendingPathComponent("mac.json"), encoding: .utf8)
        XCTAssertEqual(phone.count, mac.count)
        XCTAssertTrue(phone == mac, "embedded engine output differs from the Mac run")
    }

    func testEngineRunnerLogsRuns() async throws {
        let path = try copySource("runner")
        let db = try AppDatabase(path: path)
        let sc = try Scenario.load("typical_week", bundle: Bundle(for: Self.self))
        let log = EventLog()
        let runner = EngineRunner(db: db, clock: FixedClock(Date(timeIntervalSince1970: sc.now)),
                                  timeZone: TimeZone(identifier: sc.tz)!, log: log)
        let rec = await runner.run(EngineRunner.lightTasks, trigger: "test")
        XCTAssertTrue(rec.ok, rec.error ?? "")
        XCTAssertGreaterThan(rec.rowsWritten, 0)
        let again = await runner.run(EngineRunner.lightTasks, trigger: "test")
        XCTAssertEqual(again.rowsWritten, 0)                 // idempotent
        XCTAssertEqual(runner.history().count, 2)
        XCTAssertEqual(log.count("engine_run"), 2)
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM inferences WHERE kind = 'wind_down_plan'"), 1)
    }

    func testEngineErrorsAreLoggedNotThrown() async throws {
        let db = try AppDatabase.temporary("engine-err")
        let runner = EngineRunner(db: db, clock: SystemClock(), timeZone: .current, log: EventLog())
        let rec = await runner.run(["no_such_task_but_warn"], trigger: "t")
        XCTAssertTrue(rec.ok)                                 // unknown tasks are warnings
        try await db.writer.write { try $0.execute(sql: "DROP TABLE ai_log") }
        let bad = await runner.run(trigger: "t")
        XCTAssertFalse(bad.ok)
        XCTAssertTrue(bad.error?.contains("SchemaError") ?? false, bad.error ?? "")
    }
}
