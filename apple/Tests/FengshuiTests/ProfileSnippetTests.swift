import GRDB
import XCTest
@testable import Fengshui

final class ProfileTests: XCTestCase {
    let tz = TimeZone(identifier: "America/New_York")!
    let now = Date(timeIntervalSince1970: 1_792_519_200)  // 2026-10-20 14:00 New York

    func testSavesLoadsAndToleratesOldProfiles() throws {
        let db = try AppDatabase.temporary("profile")
        XCTAssertEqual(UserProfile.load(db), UserProfile())
        var p = UserProfile()
        p.name = "Sam Lee"
        p.goals = ["Sleep better"]
        p.stepGoal = 10_000
        try p.save(db, now: now)
        XCTAssertEqual(UserProfile.load(db), p)
        XCTAssertEqual(p.initials, "SL")
        // A profile saved before a field existed still loads, with defaults for the rest.
        try db.setPreference(UserProfile.key, ["name": "Alex"], now: now)
        XCTAssertEqual(UserProfile.load(db).name, "Alex")
        XCTAssertEqual(UserProfile.load(db).sleepGoalHours, 8)
    }

    func testPrefillsFromHealthWithoutOverwriting() throws {
        let db = try AppDatabase.temporary("profile-prefill")
        try db.writer.write { d in
            try d.execute(sql: "INSERT INTO characteristics (key, value) VALUES ('date_of_birth', '1999-04-02'), ('biological_sex', 'female')")
            try d.execute(sql: """
                INSERT INTO processed_samples (hk_uuid, hk_type, label, value, unit, start_ts, end_ts, minute_id, source_name, inserted_at)
                VALUES ('h', 'T', 'height', 1.7, 'm', 0, 0, 0, 'Health', 0)
                """)
        }
        var p = UserProfile()
        p.prefill(db)
        XCTAssertEqual(p.birthYear, 1999)
        XCTAssertEqual(p.sex, .female)
        XCTAssertEqual(p.heightCm ?? 0, 170, accuracy: 0.01)
        var mine = UserProfile()
        mine.birthYear = 2001
        mine.prefill(db)
        XCTAssertEqual(mine.birthYear, 2001)
    }

    func testClaudeContextOnlyWhenShared() throws {
        var p = UserProfile()
        p.name = "Sam Lee"
        p.birthYear = 2000
        p.goals = ["Move more"]
        let text = try XCTUnwrap(p.claudeContext(now: now, timeZone: tz))
        XCTAssertTrue(text.contains("Name: Sam"), text)
        XCTAssertFalse(text.contains("Lee"), "only the first name is shared")
        XCTAssertTrue(text.contains("Age: about 26"), text)
        XCTAssertTrue(text.contains("Goals: Move more"), text)
        p.shareWithClaude = false
        XCTAssertNil(p.claudeContext(now: now, timeZone: tz))

        let db = try AppDatabase.temporary("profile-context")
        XCTAssertEqual(ClaudeAssistant.context(db: db, now: now, timeZone: tz).count, 1)
        p.shareWithClaude = true
        try p.save(db, now: now)
        let blocks = ClaudeAssistant.context(db: db, now: now, timeZone: tz)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertTrue((blocks[1]["text"] as? String ?? "").hasPrefix("About me"))
    }
}

final class SnippetTests: XCTestCase {
    let tz = TimeZone(identifier: "America/New_York")!
    let now = Date(timeIntervalSince1970: 1_792_519_200)  // 2026-10-20 14:00 New York

    func testParsesClaudesReply() throws {
        let s = try XCTUnwrap(SnippetModel.parse("""
            TYPE: question
            TEXT: You slept 6 h 5 min. Did a late screen keep you up?
            ASK: How does screen time affect my sleep?
            """))
        XCTAssertEqual(s.kind, .question)
        XCTAssertEqual(s.text, "You slept 6 h 5 min. Did a late screen keep you up?")
        XCTAssertEqual(s.ask, "How does screen time affect my sleep?")
        XCTAssertTrue(s.byClaude)
        XCTAssertEqual(SnippetModel.parse("TYPE: insight\nTEXT: Good: 9,000 steps.")?.kind, .insight)
        XCTAssertNil(SnippetModel.parse("Sorry, I can't see any data."))
    }

    func testLocalSnippetsUseDataAndGoals() throws {
        let db = try AppDatabase.temporary("snippets")
        let t = now.timeIntervalSince1970
        try db.writer.write { d in
            // 5 h 30 min asleep last night; 1,200 steps by 14:00.
            let bed = t - 15 * 3_600
            try d.execute(sql: """
                INSERT INTO processed_samples (hk_uuid, hk_type, label, value, value_text, unit, start_ts, end_ts, minute_id, source_name, inserted_at)
                VALUES ('s1', 'T', 'sleep_analysis', NULL, 'asleep_core', NULL, ?, ?, 0, 'Watch', 0),
                       ('p1', 'T', 'step_count', 1200, NULL, 'count', ?, ?, 0, 'Watch', 0)
                """, arguments: [bed, bed + 5.5 * 3_600, t - 3_600, t - 3_600])
        }
        var profile = UserProfile()
        let empty = try db.writer.read { try SnippetModel.local($0, now: now, timeZone: tz, profile: profile) }
        let ids = empty.map(\.id)
        XCTAssertTrue(ids.contains("sleep.short"), "\(ids)")
        XCTAssertTrue(ids.contains("steps.behind"), "\(ids)")
        XCTAssertTrue(ids.contains("profile.goals"), "no goals yet → ask for them")
        XCTAssertTrue(empty.first { $0.id == "sleep.short" }!.text.contains("5 h 30 min"))

        profile.sleepGoalHours = 5
        profile.goals = ["Sit less"]
        let met = try db.writer.read { try SnippetModel.local($0, now: now, timeZone: tz, profile: profile) }.map(\.id)
        XCTAssertTrue(met.contains("sleep.good"), "\(met)")
        XCTAssertTrue(met.contains("goal.checkin"), "\(met)")
        XCTAssertFalse(met.contains("profile.goals"))
    }

    @MainActor
    func testRefreshShowsCachedClaudeSnippetFirstAndCycles() async throws {
        let env = try AppEnvironment.make(arguments: ["app", "-FengshuiTestMode", "new_user"])
        let today = SnippetModel.day(env.clock.now, env.timeZone)
        let cached = Snippet(id: "claude", kind: .insight, text: "From Claude", ask: "Why?", byClaude: true)
        try env.db.setPreference(SnippetModel.cacheKey, SnippetModel.Cached(date: today, snippet: cached), now: env.clock.now)
        let model = SnippetModel(env: env)
        await model.refresh()
        XCTAssertEqual(model.current, cached)
        XCTAssertGreaterThan(model.snippets.count, 1, "on-device snippets follow")
        model.next()
        XCTAssertNotEqual(model.current?.id, "claude")
    }
}
