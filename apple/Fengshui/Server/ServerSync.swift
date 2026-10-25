import FengshuiKit
import Foundation
import GRDB

/// Phone → Mac server (spec §12): incremental sync tracked in server_sync_state, raw
/// archive of chunks older than 7 days (payload cleared only after the server confirms),
/// and remote compute whose inference rows are inserted under the server's ids
/// (the server mirrors the phone's ids, so both sides stay identical; DECISIONS D-16).
actor ServerSync {
    struct Report: Sendable, Equatable {
        var uploaded: [String: Int] = [:]
        var archived = 0
        var computeRows = 0
        var skipped: String?
    }

    static let batch = 5_000
    static let archiveBatch = 200
    static let archiveAge: TimeInterval = 7 * 86400
    static let urlKey = "server_url"
    /// Tables whose rows change after insert: always re-sent in full (they're small) or by recency.
    static let fullTables = ["characteristics", "context_places", "preferences", "engine_state", "ai_questions",
                             "context_screen_events"]
    static let idTables = ["processed_samples", "processed_route_points", "context_motion", "context_visits",
                           "notifications_log", "inferences", "ai_log"]

    private let db: AppDatabase
    private let secrets: SecretStore
    private let network: NetworkStatus
    private let clock: Clock
    private let log: EventLog
    private let session: URLSession
    private let deviceID: String

    init(db: AppDatabase, secrets: SecretStore, network: NetworkStatus, clock: Clock, log: EventLog,
         session: URLSession = .shared, deviceID: String) {
        self.db = db
        self.secrets = secrets
        self.network = network
        self.clock = clock
        self.log = log
        self.session = session
        self.deviceID = deviceID
    }

    nonisolated var baseURL: URL? {
        ((try? db.preference(Self.urlKey, as: String.self)) ?? nil).flatMap(URL.init(string:))
    }

    func client() throws -> ServerClient {
        guard let url = baseURL, let token = secrets.get(SecretKey.serverToken), !token.isEmpty else {
            throw ServerClient.Failure.notConfigured
        }
        return ServerClient(baseURL: url, token: token, session: session)
    }

    func reachable() async -> Bool {
        guard let c = try? client() else { return false }
        return (try? await c.health())?["ok"] as? Bool == true
    }

    // MARK: Sync

    @discardableResult
    func sync(includeRaw: Bool = false) async throws -> Report {
        var rep = Report()
        guard network.onWiFi else { rep.skipped = "not on Wi-Fi"; return rep }
        let c = try client()
        let engine = try engineVersion()
        for t in Self.fullTables {
            let rows = try await rowsJSON("SELECT * FROM \(t)")
            rep.uploaded[t] = try await upload(c, engine, [t: rows])
        }
        for t in Self.idTables {
            let wm = try watermark(t)
            var last = wm
            while true {
                // Rows that change later are re-sent: open motion segments, visits, delivered
                // notifications, and inferences superseded by newer rows.
                let extra: String
                switch t {
                case "context_motion": extra = " OR end_ts IS NULL OR id > (SELECT MAX(id) - 50 FROM context_motion)"
                case "context_visits": extra = " OR departure_ts IS NULL OR arrival_ts > \(clock.now.timeIntervalSince1970 - 7 * 86400)"
                case "notifications_log": extra = " OR created_at > \(clock.now.timeIntervalSince1970 - 7 * 86400)"
                case "inferences": extra = " OR superseded_by > \(wm)"
                default: extra = ""
                }
                let sql = last == wm
                    ? "SELECT * FROM \(t) WHERE id > \(last)\(extra) ORDER BY id LIMIT \(Self.batch)"
                    : "SELECT * FROM \(t) WHERE id > \(last) ORDER BY id LIMIT \(Self.batch)"
                let rows = try await rowsJSON(sql)
                if rows.isEmpty { break }
                rep.uploaded[t, default: 0] += try await upload(c, engine, [t: rows])
                let maxID = rows.compactMap { $0["id"] as? Int64 }.max() ?? last
                try setWatermark(t, max(maxID, last))
                if rows.count < Self.batch || maxID <= last { break }
                last = maxID
            }
        }
        // HealthKit deletions of already-uploaded samples.
        let deleted = try await db.writer.read { db in
            try String.fetchAll(db, sql: "SELECT hk_uuid FROM processed_samples WHERE deleted = 1")
        }
        if !deleted.isEmpty {
            _ = try await c.post("sync", ["device_id": deviceID, "engine_version": engine, "tables": [:] as [String: Any],
                                          "deleted_uuids": deleted])
        }
        if includeRaw {
            // Unprocessed minutes only, so /compute can extract their features.
            let raw = try await rowsJSON("""
                SELECT c.* FROM raw_chunks c LEFT JOIN raw_minute_features f ON f.minute_id = c.minute_id
                WHERE c.payload IS NOT NULL AND (f.minute_id IS NULL OR c.received_at > f.computed_at) LIMIT 20000
                """)
            for part in raw.chunked(1000) { rep.uploaded["raw_chunks", default: 0] += try await upload(c, engine, ["raw_chunks": part]) }
        }
        log.add("server_sync", rep.uploaded.map { "\($0.key)+\($0.value)" }.sorted().joined(separator: " "))
        return rep
    }

    private func upload(_ c: ServerClient, _ engine: String, _ tables: [String: [[String: Any]]]) async throws -> Int {
        let r = try await c.post("sync", ["device_id": deviceID, "device_name": "iPhone", "engine_version": engine,
                                          "tables": tables])
        return (r["accepted"] as? [String: Int])?.values.reduce(0, +) ?? 0
    }

    // MARK: Raw archive (spec §12)

    @discardableResult
    func archive() async throws -> Int {
        guard network.onWiFi else { return 0 }
        let c = try client()
        let cutoff = MinuteID.from(clock.now.timeIntervalSince1970 - Self.archiveAge)
        var total = 0
        while true {
            let rows = try await rowsJSON("""
                SELECT minute_id, sensor, tier, rate_hz, sample_count, axes, encoding, scale, offset, payload FROM raw_chunks
                WHERE payload IS NOT NULL AND minute_id < \(cutoff) ORDER BY minute_id LIMIT \(Self.archiveBatch)
                """)
            if rows.isEmpty { break }
            let r = try await c.post("raw/archive", ["chunks": rows])
            let refs: [(ref: String, minute: Int, sensor: String, tier: Int)] = (r["archived"] as? [[String: Any]] ?? []).compactMap {
                guard let a = $0["archive_ref"] as? String, let m = $0["minute_id"] as? Int, let s = $0["sensor"] as? String,
                      let t = $0["tier"] as? Int else { return nil }
                return (a, m, s, t)
            }
            let now = clock.now.timeIntervalSince1970
            try await db.writer.write { db in
                for ref in refs {
                    // Only what the server confirmed loses its payload.
                    try db.execute(sql: """
                        UPDATE raw_chunks SET payload = NULL, archive_ref = ?, archived_at = ?
                        WHERE minute_id = ? AND sensor = ? AND tier = ?
                        """, arguments: [ref.ref, now, ref.minute, ref.sensor, ref.tier])
                }
            }
            total += refs.count
            if refs.count < rows.count { break }      // partial confirmation: stop, retry later
        }
        log.add("raw_archive", "\(total)")
        return total
    }

    /// Byte-exact retrieval of archived chunks (spec §12 GET /raw).
    func retrieve(sensor: String, from: Int64, to: Int64) async throws -> [(minuteID: Int64, tier: Int, payload: Data)] {
        let r = try await client().get("raw", query: ["sensor": sensor, "from_minute": "\(from)", "to_minute": "\(to)"])
        return (r["chunks"] as? [[String: Any]] ?? []).compactMap { c in
            guard let m = c["minute_id"] as? Int, let t = c["tier"] as? Int, let b = c["payload_b64"] as? String,
                  let d = Data(base64Encoded: b) else { return nil }
            return (Int64(m), t, d)
        }
    }

    // MARK: Remote compute

    /// Sync (incl. unprocessed raw), POST /compute, insert the returned rows by id.
    func compute(tasks: [String], tz: TimeZone) async throws -> Int {
        try await sync(includeRaw: true)
        let since = try await db.writer.read { db in try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(id), 0) FROM inferences") ?? 0 }
        let r = try await client().post("compute", ["engine_version": try engineVersion(), "since_id": since,
                                                    "now_ts": clock.now.timeIntervalSince1970, "tz": tz.identifier,
                                                    "tasks": tasks])
        let infs = (r["inferences"] as? [[String: Any]] ?? []).map { $0.mapValues(SendableValue.init) }
        let feats = (r["raw_minute_features"] as? [[String: Any]] ?? []).map { $0.mapValues(SendableValue.init) }
        let state = r["engine_state"] as? [String: String] ?? [:]
        try await db.writer.write { db in
            for row in infs { try Self.upsert(db, "inferences", row) }
            for row in feats { try Self.upsert(db, "raw_minute_features", row) }
            // Mirror of the engine's own state as computed on the server.
            for (k, v) in state {
                try db.execute(sql: "INSERT INTO engine_state (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                               arguments: [k, v])
            }
        }
        log.add("server_compute", "+\(infs.count) rows, \(feats.count) feature minutes")
        return infs.count
    }

    private static func upsert(_ db: Database, _ table: String, _ row: [String: SendableValue]) throws {
        let cols = row.keys.sorted()
        let args = StatementArguments(cols.map { row[$0]?.databaseValue ?? .null })
        try db.execute(sql: "INSERT OR REPLACE INTO \(table) (\(cols.joined(separator: ","))) VALUES (\(cols.map { _ in "?" }.joined(separator: ",")))",
                       arguments: args)
    }

    // MARK: Helpers

    private func engineVersion() throws -> String {
        let r = try EmbeddedPython.shared.call("version") as? [String: Any]
        return r?["version"] as? String ?? "unknown"
    }

    private func watermark(_ table: String) throws -> Int64 {
        try db.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT last_id_uploaded FROM server_sync_state WHERE table_name = ?", arguments: [table]) ?? 0
        }
    }

    private func setWatermark(_ table: String, _ id: Int64) throws {
        let now = clock.now.timeIntervalSince1970
        try db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO server_sync_state (table_name, last_id_uploaded, last_ts) VALUES (?, ?, ?)
                ON CONFLICT(table_name) DO UPDATE SET last_id_uploaded = excluded.last_id_uploaded, last_ts = excluded.last_ts
                """, arguments: [table, id, now])
        }
    }

    /// Rows as JSON-ready dictionaries; blobs become `<col>_b64`.
    private func rowsJSON(_ sql: String) async throws -> [[String: Any]] {
        let rows: [[String: SendableValue]] = try await db.writer.read { db in
            try Row.fetchAll(db, sql: sql).map { row in
                var d: [String: SendableValue] = [:]
                for (col, dbv) in row {
                    switch dbv.storage {
                    case .null: d[col] = .null
                    case .int64(let i): d[col] = .int(i)
                    case .double(let x): d[col] = .double(x)
                    case .string(let s): d[col] = .string(s)
                    case .blob(let b): d[col + "_b64"] = .string(b.base64EncodedString())
                    }
                }
                return d
            }
        }
        return rows.map { $0.mapValues(\.any) }
    }
}

enum SendableValue: Sendable {
    case null, int(Int64), double(Double), string(String)

    /// From JSONSerialization output. JSON doesn't distinguish 1 from 1.0; REAL columns
    /// convert integers on storage, so integers are kept as integers.
    init(_ v: Any) {
        switch v {
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .int(n.boolValue ? 1 : 0)
        case let n as NSNumber:
            let d = n.doubleValue
            self = (d == d.rounded() && abs(d) < 9e15 && !CFNumberIsFloatType(n)) ? .int(n.int64Value) : .double(d)
        case let s as String: self = .string(s)
        default: self = .null
        }
    }

    var databaseValue: DatabaseValue {
        switch self {
        case .null: .null
        case .int(let i): i.databaseValue
        case .double(let d): d.databaseValue
        case .string(let s): s.databaseValue
        }
    }
    var any: Any {
        switch self {
        case .null: NSNull()
        case .int(let i): i
        case .double(let d): d
        case .string(let s): s
        }
    }
}
