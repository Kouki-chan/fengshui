import FengshuiKit
import Foundation
import GRDB

/// HealthKit → processed_samples (spec §6.1).
/// Backfill and incremental sync are the same loop: anchored pages of `batchSize`,
/// each page written in one transaction together with its new anchor, so an
/// interrupted backfill resumes exactly where it stopped.
actor HealthSync {
    struct Progress: Sendable, Equatable {
        var typesDone: Int
        var typesTotal: Int
        var rowsWritten: Int
        var currentLabel: String?
        var finished: Bool { typesDone == typesTotal }
    }

    static let batchSize = 5_000

    private let db: AppDatabase
    private let store: HealthStore
    private let clock: Clock
    private let batchSize: Int
    private var exportLabels: Set<String>?

    init(db: AppDatabase, store: HealthStore, clock: Clock = SystemClock(), batchSize: Int = HealthSync.batchSize) {
        self.db = db
        self.store = store
        self.clock = clock
        self.batchSize = batchSize
    }

    /// The types this device can actually read (logged once; spec §6.1 "log which types exist").
    nonisolated func readableTypes() -> [HealthTypeInfo] {
        store.supportedTypes(HealthTypeCatalog.sampleTypes)
    }

    // MARK: Backfill / incremental

    /// Syncs every readable type from its saved anchor. On first run this is the backfill.
    @discardableResult
    func syncAll(progress: (@Sendable (Progress) -> Void)? = nil) async throws -> Int {
        let types = readableTypes()
        try await writeCharacteristics()
        var total = 0
        var p = Progress(typesDone: 0, typesTotal: types.count, rowsWritten: 0, currentLabel: nil)
        progress?(p)
        for t in types {
            p.currentLabel = t.label
            progress?(p)
            let snapshot = p
            total += try await sync(t) { written in
                var q = snapshot
                q.rowsWritten += written
                progress?(q)
            }
            p.rowsWritten = total
            p.typesDone += 1
            progress?(p)
        }
        return total
    }

    /// Incremental sync of one type (background-delivery callback). Returns rows written.
    @discardableResult
    func sync(_ type: HealthTypeInfo, pageWritten: (@Sendable (Int) -> Void)? = nil) async throws -> Int {
        var anchor = try await db.writer.read { db in
            try Data.fetchOne(db, sql: "SELECT anchor FROM sync_state WHERE hk_type = ?", arguments: [type.identifier])
        }
        var written = 0
        while true {
            let page = try await store.fetch(type, anchor: anchor, limit: batchSize)
            var routes: [String: [RoutePoint]] = [:]
            if type.kind == .workout {
                for s in page.samples { routes[s.uuid] = try await store.routePoints(workoutUUID: s.uuid) }
            }
            let n = try await write(page, type: type, routes: routes, done: !page.hasMore)
            written += n
            pageWritten?(written)
            anchor = page.anchor
            if !page.hasMore { break }
        }
        return written
    }

    func backfillDone() async throws -> Bool {
        let types = readableTypes().map(\.identifier)
        return try await db.writer.read { db in
            let done = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_state WHERE backfill_done = 1") ?? 0
            return done >= types.count
        }
    }

    // MARK: Writing

    private func write(_ page: HealthPage, type: HealthTypeInfo, routes: [String: [RoutePoint]], done: Bool) async throws -> Int {
        let now = clock.now.timeIntervalSince1970
        let labelsWithExport = try await exportLabelSet()
        return try await db.writer.write { db in
            var n = 0
            let insert = try db.makeStatement(sql: """
                INSERT OR IGNORE INTO processed_samples (hk_uuid, hk_type, label, value, value_text, unit, start_ts,
                  end_ts, minute_id, source_name, source_bundle, device, metadata_json, inserted_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """)
            for s in page.samples {
                if labelsWithExport.contains(s.label), try ExportAdoption.adopt(s, in: db) {
                    n += 1
                    continue
                }
                try insert.execute(arguments: [s.uuid, s.typeIdentifier, s.label, s.value, s.valueText, s.unit,
                                               s.start, s.end, MinuteID.from(s.start), s.sourceName, s.sourceBundle,
                                               s.device, s.metadataJSON, now])
                n += db.changesCount
            }
            if !page.deletedUUIDs.isEmpty {
                // HealthKit deletions only flag the row (spec §4: append-only except deletions).
                for chunk in page.deletedUUIDs.chunked(500) {
                    let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                    try db.execute(sql: "UPDATE processed_samples SET deleted = 1 WHERE hk_uuid IN (\(marks))",
                                   arguments: StatementArguments(chunk))
                }
            }
            for (workout, pts) in routes {
                for p in pts {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO processed_route_points (workout_uuid, ts, minute_id, lat, lon, alt_m,
                          speed_mps, h_accuracy) VALUES (?,?,?,?,?,?,?,?)
                        """, arguments: [workout, p.ts, MinuteID.from(p.ts), p.lat, p.lon, p.altitude, p.speed,
                                         p.horizontalAccuracy])
                }
            }
            try db.execute(sql: """
                INSERT INTO sync_state (hk_type, anchor, last_sync_ts, backfill_done) VALUES (?, ?, ?, ?)
                ON CONFLICT(hk_type) DO UPDATE SET anchor = excluded.anchor, last_sync_ts = excluded.last_sync_ts,
                  backfill_done = MAX(backfill_done, excluded.backfill_done)
                """, arguments: [type.identifier, page.anchor, now, done ? 1 : 0])
            return n
        }
    }

    private func writeCharacteristics() async throws {
        let chars = await store.characteristics()
        guard !chars.isEmpty else { return }
        try await db.writer.write { db in
            for (k, v) in chars {
                try db.execute(sql: "INSERT OR REPLACE INTO characteristics (key, value) VALUES (?, ?)", arguments: [k, v])
            }
        }
    }

    private func exportLabelSet() async throws -> Set<String> {
        if let s = exportLabels { return s }
        let s = try await db.writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT DISTINCT label FROM processed_samples WHERE hk_uuid LIKE 'export:%'"))
        }
        exportLabels = s
        return s
    }
}

/// Adopts rows imported from a Health export when HealthKit delivers the same sample
/// with its real UUID (DECISIONS D-06). Mirrors fengshui_engine.export_key.find_export_match.
enum ExportAdoption {
    static let timeTolerance = 1.0
    static let relTolerance = 1e-3
    static let absTolerance = 1e-2

    static func match(_ s: HealthSample, in db: Database) throws -> Int64? {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, end_ts, source_name, value, value_text FROM processed_samples
            WHERE label = ? AND start_ts BETWEEN ? AND ? AND hk_uuid LIKE 'export:%' AND deleted = 0
            """, arguments: [s.label, s.start - timeTolerance, s.start + timeTolerance])
        let hits = rows.filter { r in
            let end: Double = r["end_ts"]
            let src: String? = r["source_name"]
            let val: Double? = r["value"]
            let txt: String? = r["value_text"]
            guard abs(end - s.end) <= timeTolerance, (src ?? "") == (s.sourceName ?? "") else { return false }
            if let txt, let t = s.valueText, txt != t { return false }
            if s.label != "workout", let val, let v = s.value, abs(val - v) > max(absTolerance, relTolerance * abs(v)) {
                return false
            }
            return true
        }
        return hits.count == 1 ? hits[0]["id"] : nil
    }

    /// true if an export row was adopted (updated in place) instead of inserting.
    static func adopt(_ s: HealthSample, in db: Database) throws -> Bool {
        guard try Int.fetchOne(db, sql: "SELECT 1 FROM processed_samples WHERE hk_uuid = ?", arguments: [s.uuid]) == nil,
              let id = try match(s, in: db) else { return false }
        try db.execute(sql: """
            UPDATE processed_samples SET hk_uuid = ?, value = ?, value_text = ?, unit = ?, start_ts = ?, end_ts = ?,
              source_bundle = ?, device = COALESCE(?, device), metadata_json = COALESCE(?, metadata_json)
            WHERE id = ?
            """, arguments: [s.uuid, s.value, s.valueText, s.unit, s.start, s.end, s.sourceBundle, s.device,
                             s.metadataJSON, id])
        return true
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
