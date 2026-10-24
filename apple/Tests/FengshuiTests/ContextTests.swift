import FengshuiKit
import GRDB
import XCTest
@testable import Fengshui

/// Gate (Phase 2): visit-to-place matching, geofence registration with the fake
/// location manager, motion import idempotence. (Clustering is tested in Python.)
final class ContextTests: XCTestCase {
    let home = (lat: 40.10000, lon: -75.20000)
    let work = (lat: 40.14500, lon: -75.15500)

    func makeService(_ name: String, onHome: @escaping @Sendable (Double) async -> Void = { _ in })
        throws -> (PlaceService, FakeLocationProvider, AppDatabase) {
        let db = try AppDatabase.temporary(name)
        let loc = FakeLocationProvider()
        let s = PlaceService(db: db, location: loc, log: EventLog(), clock: FixedClock(Date(timeIntervalSince1970: 1_792_000_000)),
                             onHomeArrival: onHome)
        return (s, loc, db)
    }

    func testMatchPicksNearestPlaceWithinRadius() {
        let ps = [Place(id: 1, name: "Home", kind: .home, lat: 40.0, lon: -75.0),
                  Place(id: 2, name: "Next door", kind: .custom, lat: 40.0012, lon: -75.0),
                  Place(id: 3, name: "Suggested", kind: .suggested, lat: 40.0011, lon: -75.0, confirmed: false)]
        XCTAssertEqual(PlaceService.match(lat: 40.0001, lon: -75.0, in: ps)?.id, 1)
        XCTAssertEqual(PlaceService.match(lat: 40.0011, lon: -75.0, in: ps)?.id, 2)   // unconfirmed ignored
        XCTAssertNil(PlaceService.match(lat: 40.01, lon: -75.0, in: ps))
        XCTAssertEqual(Geo.distance(40.0, -75.0, 40.001, -75.0), 111.19, accuracy: 0.1)
    }

    func testVisitsAreMatchedOpenedAndClosed() async throws {
        let (svc, loc, db) = try makeService("visits")
        try await svc.save(name: "Home", kind: .home, lat: home.lat, lon: home.lon)
        await svc.start()
        await loc.send(.visit(arrival: 1000, departure: nil, lat: home.lat + 0.0003, lon: home.lon, hAccuracy: 20))
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM context_visits WHERE departure_ts IS NULL AND place_id IS NOT NULL"), 1)
        await loc.send(.visit(arrival: 1000, departure: 5000, lat: home.lat + 0.0003, lon: home.lon, hAccuracy: 20))
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM context_visits"), 1)
        XCTAssertEqual(try db.count("SELECT minute_end FROM context_visits"), Int(MinuteID.from(5000)))
        // Somewhere unnamed.
        await loc.send(.visit(arrival: 9000, departure: 9900, lat: 40.3, lon: -75.3, hAccuracy: 20))
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM context_visits WHERE place_id IS NULL"), 1)
        // Naming that place later re-matches its visits.
        try await svc.save(name: "Gym", kind: .custom, lat: 40.3, lon: -75.3)
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM context_visits WHERE place_id IS NULL"), 0)
    }

    func testGeofencesFollowNamedPlaces() async throws {
        let (svc, loc, db) = try makeService("fences")
        let h = try await svc.save(name: "Home", kind: .home, lat: home.lat, lon: home.lon)
        let w = try await svc.save(name: "Work", kind: .work, lat: work.lat, lon: work.lon, radius: 200)
        var ids = await loc.monitoredIdentifiers()
        XCTAssertEqual(ids, ["place-\(h)", "place-\(w)"])
        XCTAssertEqual(loc.monitored().first { $0.placeID == w }?.radius, 200)
        // Moving Home replaces it rather than adding a second one.
        let h2 = try await svc.save(name: "Home", kind: .home, lat: home.lat + 0.01, lon: home.lon)
        XCTAssertEqual(h2, h)
        XCTAssertEqual(loc.monitored().first { $0.placeID == h }?.lat ?? 0, home.lat + 0.01, accuracy: 1e-9)
        // Suggestions aren't monitored until named.
        try await db.writer.write { d in
            try d.execute(sql: "INSERT INTO context_places (name, kind, lat, lon, radius_m, confirmed, created_at) VALUES ('s','suggested',40.2,-75.2,150,0,0)")
        }
        await svc.syncGeofences()
        ids = await loc.monitoredIdentifiers()
        XCTAssertEqual(ids.count, 2)
        try await svc.delete(w)
        ids = await loc.monitoredIdentifiers()
        XCTAssertEqual(ids, ["place-\(h)"])
    }

    func testHomeEntryFiresHookOnlyForHome() async throws {
        let arrivals = Box()
        let (svc, loc, _) = try makeService("homehook") { ts in await arrivals.add("\(Int(ts))") }
        let h = try await svc.save(name: "Home", kind: .home, lat: home.lat, lon: home.lon)
        let w = try await svc.save(name: "Work", kind: .work, lat: work.lat, lon: work.lon)
        await svc.start()
        await loc.send(.region(identifier: "place-\(w)", entered: true, at: 100))
        await loc.send(.region(identifier: "place-\(h)", entered: false, at: 200))
        await loc.send(.region(identifier: "place-\(h)", entered: true, at: 300))
        let got = await arrivals.items
        XCTAssertEqual(got, ["300"])
    }

    func testStartIsIdempotent() async throws {
        let (svc, loc, _) = try makeService("start")
        await svc.start()
        await svc.start()
        XCTAssertEqual(loc.setGeofencesCalls, 1)
    }

    func testSuggestionConfirmAndDismiss() async throws {
        let (svc, _, db) = try makeService("suggest")
        try await db.writer.write { d in
            try d.execute(sql: "INSERT INTO context_places (name, kind, lat, lon, radius_m, confirmed, created_at) VALUES ('a','suggested',40.2,-75.2,150,0,0), ('b','suggested',40.25,-75.2,150,0,0)")
        }
        let ps = try svc.places().filter { $0.kind == .suggested }
        try await svc.confirmSuggestion(ps[0].id, name: "Gym")
        try await svc.dismissSuggestion(ps[1].id)
        XCTAssertEqual(try svc.places().map(\.name), ["Gym"])
        XCTAssertEqual(try db.preference("dismissed_places", as: [[Double]].self), [[40.25, -75.2]])
    }

    // MARK: Motion

    func testMotionSegmentsMergeRepeats() {
        let s = CoreMotionHistory.toSegments([(0, "stationary", 2), (60, "stationary", 1), (120, "walking", 2), (300, "automotive", 1)])
        XCTAssertEqual(s, [MotionSegment(start: 0, end: 120, activity: "stationary", confidence: 2),
                           MotionSegment(start: 120, end: 300, activity: "walking", confidence: 2),
                           MotionSegment(start: 300, end: nil, activity: "automotive", confidence: 1)])
    }

    func testMotionImportIsIdempotentAndClosesOpenSegment() async throws {
        let db = try AppDatabase.temporary("motion")
        let now = 1_792_000_000.0
        let fake = FakeMotionHistory([MotionSegment(start: now - 3600, end: now - 1800, activity: "walking", confidence: 2),
                                      MotionSegment(start: now - 1800, end: nil, activity: "automotive", confidence: 1)])
        let imp = MotionImporter(db: db, history: fake, clock: FixedClock(Date(timeIntervalSince1970: now)))
        try await imp.importNew()
        try await imp.importNew()
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM context_motion"), 2)
        // The second query starts at the last stored segment, not 7 days back.
        XCTAssertEqual(fake.queries.last?.0, now - 1800)
        fake.all[1].end = now - 60
        fake.all.append(MotionSegment(start: now - 60, end: nil, activity: "stationary", confidence: 2))
        try await imp.importNew()
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM context_motion"), 3)
        XCTAssertEqual(try db.count("SELECT CAST(end_ts AS INT) FROM context_motion WHERE activity = 'automotive'"), Int(now - 60))
    }

    func testFirstMotionImportLooksBackSevenDays() async throws {
        let db = try AppDatabase.temporary("motion7")
        let now = 1_792_000_000.0
        let fake = FakeMotionHistory()
        try await MotionImporter(db: db, history: fake, clock: FixedClock(Date(timeIntervalSince1970: now))).importNew()
        XCTAssertEqual(fake.queries.first?.0, now - 7 * 86400)
    }
}
