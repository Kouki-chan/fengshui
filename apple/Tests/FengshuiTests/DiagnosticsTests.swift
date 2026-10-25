import FengshuiKit
import GRDB
import XCTest
@testable import Fengshui

final class DiagnosticsTests: XCTestCase {
    func testReportCoversDeviceChecksAndHasNoSecrets() async throws {
        let env = try AppEnvironment.make(arguments: ["x", "-FengshuiTestMode", "typical_week"])
        env.secrets.set(SecretKey.serverToken, "super-secret-token-123")
        env.secrets.set(SecretKey.anthropicKey, "fake-claude-key-456")
        try await env.healthSync.syncAll()
        await env.engine.run(trigger: "test")
        let report = await Diagnostics(env: env).run()
        let names = Set(report.checks.map(\.name))
        for n in ["healthkit_types_readable", "healthkit_data_arrived", "backfill_done", "background_delivery_registered",
                  "background_delivery_fired", "last_sync_heart_rate", "location_always", "watch_paired_app_installed",
                  "raw_coverage_24h", "engine_last_run", "tonight_notification_scheduled", "server_reachable",
                  "claude_key_present", "signing_expiry"] {
            XCTAssertTrue(names.contains(n), n)
        }
        XCTAssertTrue(report.checks.first { $0.name == "engine_last_run" }!.ok)
        XCTAssertTrue(report.checks.first { $0.name == "claude_key_present" }!.ok)
        let json = String(data: try JSONEncoder().encode(report), encoding: .utf8)!
        XCTAssertFalse(json.contains("super-secret-token-123"))
        XCTAssertFalse(json.contains("fake-claude-key"))
        XCTAssertNotNil(report.metrics["app_bundle_bytes"])
    }

    func testCompressionRatioFromStoredChunks() throws {
        let src = repoRoot.appendingPathComponent("build/parity/source.sqlite")
        guard FileManager.default.fileExists(atPath: src.path) else { throw XCTSkip("run engine/tests/parity.py first") }
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("ratio-\(UUID()).sqlite")
        try FileManager.default.copyItem(at: src, to: dst)
        let env = try AppEnvironment.make(arguments: ["x", "-FengshuiTestMode", "new_user"])
        _ = env
        let db = try AppDatabase(path: dst.path)
        let r = try db.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT SUM(sample_count * axes * 4) AS f, SUM(LENGTH(payload)) AS z FROM raw_chunks WHERE sensor = 'accel'")!
        }
        let ratio = Double(r["f"] as Int64) / Double(r["z"] as Int64)
        XCTAssertGreaterThan(ratio, 2.0)
        print(String(format: "METRIC synthetic_db_compression_ratio=%.2f", ratio))
    }

    func testDatabaseExportIsConsistentCopy() async throws {
        let db = try AppDatabase.temporary("export-src")
        try await db.writer.write { d in
            for i in 0..<500 {
                try d.execute(sql: "INSERT INTO processed_samples (hk_uuid, hk_type, label, start_ts, end_ts, minute_id, inserted_at) VALUES (?, 'T', 'x', 0, 0, 0, 0)",
                              arguments: ["u\(i)"])
            }
        }
        let url = try await DatabaseExport.makeCopy(db)
        let copy = try AppDatabase(path: url.path)
        XCTAssertEqual(try copy.count("SELECT COUNT(*) FROM processed_samples"), 500)
        let r = try EmbeddedPython.shared.call("check_schema", ["db_path": url.path]) as! [String: Any]
        XCTAssertEqual(r["schema_version"] as? Int, 1)
    }

    /// Privacy review: no code path logs a secret (event log, ai_log, diagnostics).
    func testEventLogNeverContainsSecrets() async throws {
        let env = try AppEnvironment.make(arguments: ["x", "-FengshuiTestMode", "new_user"])
        env.secrets.set(SecretKey.serverToken, "tok-should-not-appear")
        try env.db.setPreference(ServerSync.urlKey, "http://127.0.0.1:9")
        _ = try? await env.server.sync()
        _ = await env.server.reachable()
        for e in env.log.events { XCTAssertFalse(e.detail.contains("tok-should-not-appear")) }
        let prefs = try await env.db.writer.read { try String.fetchAll($0, sql: "SELECT value_json FROM preferences") }
        XCTAssertFalse(prefs.joined().contains("tok-should-not-appear"))
    }
}
