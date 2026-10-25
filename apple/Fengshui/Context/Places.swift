import FengshuiKit
import Foundation
import GRDB
import Synchronization

struct Place: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable, CaseIterable { case home, work, custom, suggested }
    var id: Int64
    var name: String
    var kind: Kind
    var lat: Double
    var lon: Double
    var radius: Double
    var confirmed: Bool

    init(row: Row) {
        id = row["id"]; name = row["name"]; kind = Kind(rawValue: row["kind"]) ?? .custom
        lat = row["lat"]; lon = row["lon"]; radius = row["radius_m"]; confirmed = (row["confirmed"] as Int) == 1
    }

    init(id: Int64, name: String, kind: Kind, lat: Double, lon: Double, radius: Double = 150, confirmed: Bool = true) {
        self.id = id; self.name = name; self.kind = kind; self.lat = lat; self.lon = lon
        self.radius = radius; self.confirmed = confirmed
    }
}

enum Geo {
    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        // Haversine; same as fengshui_engine.places.haversine_m.
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = p2 - p1, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(sqrt(a))
    }
}

/// Places, visits and geofences (spec §6.2).
final class PlaceService: Sendable {
    let db: AppDatabase
    let location: LocationProvider
    let log: EventLog
    private let clock: Clock
    /// Called when the user arrives Home (used by wind-down, spec §10.2 step 7 / §11).
    let onHomeArrival: @Sendable (Double) async -> Void
    /// Any visit / region event triggers a light engine run (spec §9).
    let onVisit: @Sendable () async -> Void

    /// iOS allows 20 monitored conditions per app; named places are far fewer.
    static let maxGeofences = 20

    init(db: AppDatabase, location: LocationProvider, log: EventLog, clock: Clock,
         onHomeArrival: @escaping @Sendable (Double) async -> Void = { _ in },
         onVisit: @escaping @Sendable () async -> Void = {}) {
        self.db = db; self.location = location; self.log = log; self.clock = clock
        self.onHomeArrival = onHomeArrival
        self.onVisit = onVisit
    }

    // MARK: Places

    func places(includeSuggested: Bool = true) throws -> [Place] {
        try db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM context_places ORDER BY CASE kind WHEN 'home' THEN 0 WHEN 'work' THEN 1 WHEN 'custom' THEN 2 ELSE 3 END, id")
                .map(Place.init(row:)).filter { includeSuggested || $0.kind != .suggested }
        }
    }

    /// Adds a named place, or replaces the existing Home / Work.
    @discardableResult
    func save(name: String, kind: Place.Kind, lat: Double, lon: Double, radius: Double = 150) async throws -> Int64 {
        let now = clock.now.timeIntervalSince1970
        let id = try await db.writer.write { db -> Int64 in
            if kind == .home || kind == .work,
               let existing = try Int64.fetchOne(db, sql: "SELECT id FROM context_places WHERE kind = ?", arguments: [kind.rawValue]) {
                try db.execute(sql: "UPDATE context_places SET name = ?, lat = ?, lon = ?, radius_m = ? WHERE id = ?",
                               arguments: [name, lat, lon, radius, existing])
                return existing
            }
            try db.execute(sql: """
                INSERT INTO context_places (name, kind, lat, lon, radius_m, confirmed, created_at) VALUES (?,?,?,?,?,1,?)
                """, arguments: [name, kind.rawValue, lat, lon, radius, now])
            return db.lastInsertedRowID
        }
        try await rematchVisits()
        await syncGeofences()
        return id
    }

    /// Names a suggestion (spec §6.2: "shows them for naming or dismissal").
    func confirmSuggestion(_ id: Int64, name: String) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE context_places SET name = ?, kind = 'custom', confirmed = 1 WHERE id = ?",
                           arguments: [name, id])
        }
        try await rematchVisits()
        await syncGeofences()
    }

    /// Removes a suggestion and remembers the spot so the engine doesn't suggest it again.
    func dismissSuggestion(_ id: Int64) async throws {
        try await db.writer.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT lat, lon FROM context_places WHERE id = ?", arguments: [id]) else { return }
            var list = (try String.fetchOne(db, sql: "SELECT value_json FROM preferences WHERE key = 'dismissed_places'"))
                .flatMap { try? JSONDecoder().decode([[Double]].self, from: Data($0.utf8)) } ?? []
            list.append([row["lat"], row["lon"]])
            let json = String(data: try JSONEncoder().encode(list), encoding: .utf8)!
            try db.execute(sql: """
                INSERT INTO preferences (key, value_json, updated_at) VALUES ('dismissed_places', ?, ?)
                ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json, updated_at = excluded.updated_at
                """, arguments: [json, self.clock.now.timeIntervalSince1970])
            try db.execute(sql: "DELETE FROM context_places WHERE id = ?", arguments: [id])
        }
    }

    func delete(_ id: Int64) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE context_visits SET place_id = NULL WHERE place_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM context_places WHERE id = ?", arguments: [id])
        }
        await syncGeofences()
    }

    // MARK: Matching

    /// Nearest confirmed place whose radius contains the point (else nil). Mirrors
    /// engine/tests/scenario_db.match_place.
    static func match(lat: Double, lon: Double, in places: [Place]) -> Place? {
        places.filter { $0.confirmed }
            .map { ($0, Geo.distance(lat, lon, $0.lat, $0.lon)) }
            .filter { $0.1 <= $0.0.radius }
            .min { $0.1 < $1.1 }?.0
    }

    /// Re-run matching for unmatched visits after places change.
    func rematchVisits() async throws {
        let ps = try places(includeSuggested: false)
        try await db.writer.write { db in
            for r in try Row.fetchAll(db, sql: "SELECT id, lat, lon FROM context_visits WHERE place_id IS NULL") {
                if let p = Self.match(lat: r["lat"], lon: r["lon"], in: ps) {
                    try db.execute(sql: "UPDATE context_visits SET place_id = ? WHERE id = ?", arguments: [p.id, r["id"] as Int64])
                }
            }
        }
    }

    // MARK: Events

    private let started = Mutex(false)

    /// Idempotent: called on every launch / foreground, starts monitoring once per process.
    func start() async {
        let first = started.withLock { s in defer { s = true }; return !s }
        guard first else { return }
        await location.start { [weak self] e in await self?.handle(e) }
        await syncGeofences()
    }

    func syncGeofences() async {
        let regions = ((try? places(includeSuggested: false)) ?? []).prefix(Self.maxGeofences).map {
            PlaceRegion(placeID: $0.id, lat: $0.lat, lon: $0.lon, radius: $0.radius)
        }
        await location.setGeofences(Array(regions))
        log.add("geofences", "\(regions.count)")
    }

    func handle(_ e: LocationEvent) async {
        switch e {
        case let .visit(arrival, departure, lat, lon, acc):
            do { try await recordVisit(arrival: arrival, departure: departure, lat: lat, lon: lon, hAccuracy: acc) } catch {
                log.add("visit_error", "\(error)")
            }
            await onVisit()
        case let .region(id, entered, at):
            log.add(entered ? "region_enter" : "region_exit", id)
            if entered, let home = try? places().first(where: { $0.kind == .home }), id == "place-\(home.id)" {
                await onHomeArrival(at)
            } else {
                await onVisit()
            }
        case .significantChange:
            log.add("significant_change")
        }
    }

    /// Arrival-only visits are stored with departure NULL and closed by the later
    /// departure event for the same arrival (spec §5 context_visits).
    func recordVisit(arrival: Double, departure: Double?, lat: Double, lon: Double, hAccuracy: Double) async throws {
        let place = Self.match(lat: lat, lon: lon, in: try places(includeSuggested: false))
        try await db.writer.write { db in
            if let open = try Int64.fetchOne(db, sql: """
                SELECT id FROM context_visits WHERE ABS(arrival_ts - ?) < 60 ORDER BY id DESC LIMIT 1
                """, arguments: [arrival]) {
                if let departure {
                    try db.execute(sql: "UPDATE context_visits SET departure_ts = ?, minute_end = ? WHERE id = ?",
                                   arguments: [departure, MinuteID.from(departure), open])
                }
                return
            }
            try db.execute(sql: """
                INSERT INTO context_visits (place_id, lat, lon, h_accuracy, arrival_ts, departure_ts, minute_start, minute_end)
                VALUES (?,?,?,?,?,?,?,?)
                """, arguments: [place?.id, lat, lon, hAccuracy, arrival, departure, MinuteID.from(arrival),
                                 departure.map(MinuteID.from)])
        }
        log.add("visit", place?.name ?? "unnamed place")
    }
}
