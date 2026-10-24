import FengshuiKit
import GRDB
import XCTest
@testable import Fengshui

/// Spike A: the embedded engine runs inside the simulator app and reads SQLite.
final class EmbeddedPythonTests: XCTestCase {
    func testVersion() throws {
        let r = try EmbeddedPython.shared.call("version") as! [String: Any]
        XCTAssertEqual(r["version"] as? String, "0.1.0")
        XCTAssertEqual(r["platform"] as? String, "ios")
        XCTAssertTrue((r["python"] as? String ?? "").hasPrefix("3.13"))
        if let s = EmbeddedPython.shared.startupSeconds {
            print("METRIC python_startup_s=\(String(format: "%.3f", s))")
        }
    }

    func testReadsSQLiteCreatedBySwift() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spikeA-\(UUID()).sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in try db.execute(sql: Schema.sql()) }
        let r = try EmbeddedPython.shared.call("sqlite_probe", ["db_path": url.path]) as! [String: Any]
        XCTAssertEqual(r["schema_version"] as? Int, 1)
        XCTAssertTrue((r["tables"] as? [String] ?? []).contains("processed_samples"))
    }

    func testZoneInfoWorks() throws {
        let r = try EmbeddedPython.shared.call("zoneinfo_probe", ["tz": "America/New_York", "ts": 1792843200]) as! [String: Any]
        XCTAssertEqual(r["local"] as? String, "2026-10-24T08:00:00-04:00")
    }

    func testEngineErrorsSurface() {
        XCTAssertThrowsError(try EmbeddedPython.shared.call("no_such_function")) { error in
            XCTAssertTrue("\(error)".contains("KeyError"))
        }
    }

    func testStartupTimeMeasured() throws {
        try EmbeddedPython.shared.initializeIfNeeded()
        let t0 = Date()
        _ = try EmbeddedPython.shared.call("version")
        print("METRIC python_call_roundtrip_s=\(String(format: "%.4f", Date().timeIntervalSince(t0)))")
    }
}
