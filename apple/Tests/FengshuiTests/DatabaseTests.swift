import FengshuiKit
import GRDB
import XCTest
@testable import Fengshui

final class DatabaseTests: XCTestCase {
    func testMigrationsCreateSchemaThePythonEngineAccepts() throws {
        let db = try AppDatabase.temporary("schema")
        let r = try EmbeddedPython.shared.call("check_schema", ["db_path": db.path]) as! [String: Any]
        XCTAssertEqual(r["schema_version"] as? Int, 1)
        // Copy for the Mac-side pytest (engine/tests/test_swift_db.py).
        let out = repoRoot.appendingPathComponent("build/swift_created.sqlite")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: out)
        try db.writer.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        try FileManager.default.copyItem(atPath: db.path, toPath: out.path)
    }

    func testPragmas() throws {
        let db = try AppDatabase.temporary("pragmas")
        try db.writer.read { d in
            XCTAssertEqual(try String.fetchOne(d, sql: "PRAGMA journal_mode"), "wal")
            XCTAssertEqual(try Int.fetchOne(d, sql: "PRAGMA foreign_keys"), 1)
            XCTAssertEqual(try Int.fetchOne(d, sql: "PRAGMA busy_timeout"), 5000)
        }
    }

    func testMigrationIsIdempotentOnReopen() throws {
        let db = try AppDatabase.temporary("reopen")
        let again = try AppDatabase(path: db.path)
        XCTAssertEqual(try again.count("SELECT COUNT(*) FROM schema_version"), 1)
    }

    func testOpensDatabaseCreatedByPython() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("py-\(UUID()).sqlite")
        let q = try DatabaseQueue(path: url.path)
        try q.write { try $0.execute(sql: Schema.sql()) }      // as fengshui_engine.db.create does
        try q.close()
        let db = try AppDatabase(path: url.path)
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM schema_version"), 1)
    }

    func testPreferencesRoundTrip() throws {
        let db = try AppDatabase.temporary("prefs")
        try db.setPreference("x", ["a": 1])
        try db.setPreference("x", ["a": 2])
        XCTAssertEqual(try db.preference("x", as: [String: Int].self), ["a": 2])
    }
}
