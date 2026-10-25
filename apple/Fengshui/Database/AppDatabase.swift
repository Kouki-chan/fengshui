import FengshuiKit
import Foundation
import GRDB

/// The phone's SQLite database (spec §4–5). Swift writes the collection tables;
/// the embedded Python engine writes inferences / features / engine_state.
final class AppDatabase: Sendable {
    let writer: any DatabaseWriter
    let path: String

    init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }
        // DatabasePool = WAL mode, so the Python engine can read while Swift writes.
        writer = try DatabasePool(path: path, configuration: config)
        self.path = path
        try Self.migrator.migrate(writer)
    }

    /// Numbered migrations. v1 executes the shared schema file (DECISIONS D-04);
    /// later versions append here and in fengshui_engine.db.
    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            // A DB created by Python (importer, server, restored backup) already has v1
            // but no GRDB migration record: adopt it instead of failing.
            if try db.tableExists("schema_version"),
               try Int.fetchOne(db, sql: "SELECT MAX(version) FROM schema_version") == 1 {
                return
            }
            try db.execute(sql: try Schema.sql(version: 1))
        }
        return m
    }

    /// Default location: the App Group container, so extensions can reach it later.
    static func defaultURL() -> URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.chevin.fengshui")
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("fengshui.sqlite")
    }

    static func temporary(_ name: String = UUID().uuidString) throws -> AppDatabase {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fs-\(name).sqlite")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        return try AppDatabase(path: url.path)
    }

    // MARK: Preferences (JSON values)

    func preference<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        try writer.read { db in
            guard let json = try String.fetchOne(db, sql: "SELECT value_json FROM preferences WHERE key = ?",
                                                 arguments: [key]) else { return nil }
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        }
    }

    func setPreference<T: Encodable>(_ key: String, _ value: T, now: Date = Date()) throws {
        let json = String(data: try JSONEncoder.sorted.encode(value), encoding: .utf8)!
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO preferences(key, value_json, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json, updated_at = excluded.updated_at
                """, arguments: [key, json, now.timeIntervalSince1970])
        }
    }

    // MARK: Debug helpers

    func rowCounts() throws -> [String: Int] {
        try writer.read { db in
            var out: [String: Int] = [:]
            for t in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") {
                out[t] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(t)\"") ?? 0
            }
            return out
        }
    }

    func labelCounts() throws -> [(label: String, count: Int)] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT label, COUNT(*) AS n FROM processed_samples WHERE deleted = 0 GROUP BY label ORDER BY label
                """).map { ($0["label"], $0["n"]) }
        }
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
