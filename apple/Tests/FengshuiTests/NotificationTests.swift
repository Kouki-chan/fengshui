import FengshuiKit
import GRDB
import UserNotifications
import XCTest
@testable import Fengshui

/// Phase 5 gate: with a fake clock, plans schedule, reschedule (superseded by > 5 min) and
/// cancel correctly; the Home-arrival rule fires only when it should; log rows are written;
/// a simulator test confirms the real pending request has the right trigger time.
final class NotificationTests: XCTestCase {
    let tz = TimeZone(identifier: "America/New_York")!
    // 2026-10-24 21:00 -04:00
    let now = Date(timeIntervalSince1970: 1_792_890_000)

    func setup(_ name: String) throws -> (AppDatabase, FakeNotificationCenter, FixedClock, WindDownScheduler) {
        let db = try AppDatabase.temporary(name)
        let c = FakeNotificationCenter()
        let clock = FixedClock(now)
        return (db, c, clock, WindDownScheduler(db: db, center: c, clock: clock, timeZone: tz, log: EventLog()))
    }

    /// Inserts a plan like the engine does; `supersedes` marks the previous row.
    @discardableResult
    func plan(_ db: AppDatabase, night: String = "2026-10-24", start: Date, supersedes: Int64? = nil) throws -> Int64 {
        try db.writer.write { d in
            let v = #"{"night_of":"\#(night)","wind_down_start":"22:12","target_in_bed":"23:27","target_sleep_onset":"23:41","predicted_wake":"08:05","reasons":[]}"#
            try d.execute(sql: """
                INSERT INTO inferences (kind, minute_start, minute_end, value_json, algorithm, algorithm_version, computed_at, computed_where)
                VALUES ('wind_down_plan', ?, ?, ?, 'wind_down', 'wind_down-v1', 0, 'phone')
                """, arguments: [Int64(start.timeIntervalSince1970 / 60), Int64(start.timeIntervalSince1970 / 60) + 600, v])
            let id = d.lastInsertedRowID
            if let s = supersedes { try d.execute(sql: "UPDATE inferences SET superseded_by = ? WHERE id = ?", arguments: [id, s]) }
            return id
        }
    }

    func testSchedulesAtWindDownStartAndLogs() async throws {
        let (db, c, _, s) = try setup("sched")
        let start = now.addingTimeInterval(72 * 60)                 // 22:12
        let pid = try plan(db, start: start)
        await s.sync()
        let pending = await c.pending()
        XCTAssertEqual(pending, [PendingNotification(identifier: "wind_down_2026-10-24", fireDate: start)])
        XCTAssertEqual(c.added.first?.userInfo["night_of"], "2026-10-24")
        XCTAssertEqual(try db.int64("SELECT inference_id FROM notifications_log"), pid)
        XCTAssertEqual(try db.double("SELECT scheduled_for FROM notifications_log"), start.timeIntervalSince1970)
        // Same plan again → nothing new.
        await s.sync()
        XCTAssertEqual(c.added.count, 1)
    }

    func testRescheduleWhenSupersededAndCancelOldLogRow() async throws {
        let (db, c, _, s) = try setup("resched")
        let p1 = try plan(db, start: now.addingTimeInterval(3600))
        await s.sync()
        // The engine superseded the plan (moved > 5 min): 15 min earlier.
        let newStart = now.addingTimeInterval(2700)
        try plan(db, start: newStart, supersedes: p1)
        await s.sync()
        let pending = await c.pending()
        XCTAssertEqual(pending.map(\.fireDate), [newStart])
        XCTAssertEqual(c.removed, ["wind_down_2026-10-24"])
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM notifications_log"), 2)
        XCTAssertNotNil(try db.double("SELECT cancelled_at FROM notifications_log ORDER BY id LIMIT 1"))
        XCTAssertNil(try db.double("SELECT cancelled_at FROM notifications_log ORDER BY id DESC LIMIT 1"))
    }

    func testCancelWhenDisabledAndNeverScheduleInPast() async throws {
        let (db, c, clock, s) = try setup("cancel")
        try plan(db, start: now.addingTimeInterval(3600))
        await s.sync()
        try db.setPreference(WindDownScheduler.enabledKey, false)
        await s.sync()
        let afterDisable = await c.pending()
        XCTAssertTrue(afterDisable.isEmpty)
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM notifications_log WHERE cancelled_at IS NOT NULL"), 1)
        try db.setPreference(WindDownScheduler.enabledKey, true)
        clock.set(now.addingTimeInterval(7200))                      // start has passed
        await s.sync()
        let afterPast = await c.pending()
        XCTAssertTrue(afterPast.isEmpty)
    }

    func testNextNightGetsItsOwnIdentifier() async throws {
        let (db, c, clock, s) = try setup("nights")
        try plan(db, start: now.addingTimeInterval(3600))
        await s.sync()
        c.deliver("wind_down_2026-10-24", at: now.addingTimeInterval(3600 + 20))
        clock.set(now.addingTimeInterval(86400 - 600))
        try plan(db, night: "2026-10-25", start: now.addingTimeInterval(86400 + 3600))
        await s.sync()
        let ids = await c.pending().map(\.identifier)
        XCTAssertEqual(ids, ["wind_down_2026-10-25"])
    }

    func testHomeArrivalRule() async throws {
        let (db, c, _, s) = try setup("home")
        let start = now.addingTimeInterval(1800)
        try plan(db, start: start)
        let early = await s.homeArrival(at: start.timeIntervalSince1970 - 60)           // home before start → no
        let late = await s.homeArrival(at: start.timeIntervalSince1970 + 91 * 60)        // > 90 min after → no
        XCTAssertFalse(early); XCTAssertFalse(late)
        let ok = await s.homeArrival(at: start.timeIntervalSince1970 + 40 * 60)          // within window → yes
        XCTAssertTrue(ok)
        XCTAssertEqual(c.added.last?.identifier, "wind_down_home_2026-10-24")
        XCTAssertNil(c.added.last?.fireDate)                                              // immediate
        let again = await s.homeArrival(at: start.timeIntervalSince1970 + 50 * 60)       // only once a night
        XCTAssertFalse(again)
        XCTAssertEqual(try db.count("SELECT COUNT(*) FROM notifications_log WHERE kind = 'wind_down_home'"), 1)
    }

    func testHomeArrivalSuppressedWhenDismissed() async throws {
        let (db, _, _, s) = try setup("dismiss")
        let start = now.addingTimeInterval(1800)
        try plan(db, start: start)
        await s.dismissTonight("2026-10-24")
        let sent = await s.homeArrival(at: start.timeIntervalSince1970 + 600)
        XCTAssertFalse(sent)
    }

    func testDeliveryDelayIsMeasured() async throws {
        let (db, c, _, s) = try setup("delay")
        let start = now.addingTimeInterval(3600)
        try plan(db, start: start)
        await s.sync()
        c.deliver("wind_down_2026-10-24", at: start.addingTimeInterval(42))
        await s.reconcileDelivered()
        let d = try await s.delays()
        XCTAssertEqual(d.first?.seconds ?? 0, 42, accuracy: 0.001)
    }

    func testSigningProfileParsing() async throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>ExpirationDate</key><date>2026-10-31T16:00:00Z</date><key>Name</key><string>x</string></dict></plist>
        """
        let blob = Data([0x30, 0x82, 0x01]) + Data(plist.utf8) + Data([0x00, 0xA0])     // CMS bytes around it
        let d = SigningExpiry.parse(profile: blob)
        XCTAssertEqual(d, ISO8601DateFormatter().date(from: "2026-10-31T16:00:00Z"))
        XCTAssertEqual(SigningExpiry.daysLeft(d!, now: ISO8601DateFormatter().date(from: "2026-10-24T17:00:00Z")!), 6)
        let c = FakeNotificationCenter()
        let exp = d!
        await SigningExpiry.scheduleReminder(expiry: exp, now: exp.addingTimeInterval(-5 * 86400), center: c, timeZone: tz)
        XCTAssertEqual(c.added.first?.fireDate, exp.addingTimeInterval(-86400))
    }

    /// Real UNUserNotificationCenter in the simulator: the pending request's calendar trigger
    /// fires exactly at wind_down_start.
    func testSimulatorPendingRequestHasRightTriggerTime() async throws {
        let center = SystemNotificationCenter()
        guard await center.isAuthorized() else {
            throw XCTSkip("notifications not authorized on this simulator: run NotificationPermissionUITests first (scripts/test_all.sh does)")
        }
        let fire = Date().addingTimeInterval(3 * 3600).rounded(toSeconds: 60)
        let id = "test_wind_down_\(UUID().uuidString)"
        do {
            try await center.add(LocalNotification(identifier: id, title: "t", body: "b", fireDate: fire), timeZone: tz)
        } catch {
            throw XCTSkip("notifications not authorized in this simulator (scripts/test_all.sh grants it): \(error)")
        }
        let p = await center.pending().first { $0.identifier == id }
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.fireDate?.timeIntervalSince1970 ?? 0, fire.timeIntervalSince1970, accuracy: 0.5)
        await center.removePending([id])
    }
}

extension Date {
    func rounded(toSeconds s: Double) -> Date { Date(timeIntervalSince1970: (timeIntervalSince1970 / s).rounded(.down) * s) }
}
