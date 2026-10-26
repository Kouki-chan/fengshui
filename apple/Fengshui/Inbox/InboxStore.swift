import FengshuiKit
import Foundation
import GRDB

/// In-app inbox behind the bell button (DECISIONS D-20): every notification the user received
/// (wind-down, Home arrival, scheduled answers, monitor alerts, report-ready, signing expiry),
/// plus messages the app adds directly. Phone-only; never synced or sent to Claude.
struct InboxMessage: Sendable, Equatable, Identifiable {
    var id: Int64
    var identifier: String
    var ts: Double
    var kind: String
    var title: String
    var body: String
    var readAt: Double?
    /// e.g. "report:12": opens that report.
    var link: String?
    var isRead: Bool { readAt != nil }
}

final class InboxStore: Sendable {
    static let deleteAfterReadKey = "inbox_delete_after_read"

    private let db: AppDatabase
    private let clock: Clock
    private let center: NotificationCenter

    init(db: AppDatabase, clock: Clock, center: NotificationCenter) {
        self.db = db
        self.clock = clock
        self.center = center
    }

    var deleteAfterRead: Bool {
        get { ((try? db.preference(Self.deleteAfterReadKey, as: Bool.self)) ?? nil) ?? false }
    }

    func setDeleteAfterRead(_ on: Bool) {
        try? db.setPreference(Self.deleteAfterReadKey, on, now: clock.now)
    }

    /// Inserts once per identifier; returns true when new.
    @discardableResult
    func add(identifier: String, kind: String, title: String, body: String, at ts: Date? = nil, link: String? = nil) -> Bool {
        let n = (try? db.writer.write { db -> Int in
            try db.execute(sql: """
                INSERT OR IGNORE INTO inbox_messages (identifier, ts, kind, title, body, link) VALUES (?,?,?,?,?,?)
                """, arguments: [identifier, (ts ?? clock.now).timeIntervalSince1970, kind, title, body, link])
            return db.changesCount
        }) ?? 0
        return n > 0
    }

    /// Copies notifications that iOS delivered (even while the app was closed) into the inbox.
    func ingestDelivered() async {
        for d in await center.deliveredContent() where !d.title.isEmpty || !d.body.isEmpty {
            add(identifier: d.identifier, kind: d.kind ?? Self.kind(for: d.identifier), title: d.title, body: d.body,
                at: d.date)
        }
        await updateBadge()
    }

    static func kind(for identifier: String) -> String {
        for (prefix, kind) in [("wind_down", "wind_down"), ("home_", "wind_down"), ("monitor", "monitor"),
                               ("ai_", "answer"), ("question", "answer"), ("signing", "system"), ("report", "report")]
        where identifier.hasPrefix(prefix) { return kind }
        return "other"
    }

    func all() -> [InboxMessage] {
        (try? db.writer.read { try Self.fetchAll($0) }) ?? []
    }

    static func fetchAll(_ db: Database) throws -> [InboxMessage] {
        try Row.fetchAll(db, sql: "SELECT * FROM inbox_messages ORDER BY ts DESC, id DESC LIMIT 500").map {
            InboxMessage(id: $0["id"], identifier: $0["identifier"], ts: $0["ts"], kind: $0["kind"], title: $0["title"],
                         body: $0["body"], readAt: $0["read_at"], link: $0["link"])
        }
    }

    static func unread(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_messages WHERE read_at IS NULL") ?? 0
    }

    func unreadCount() -> Int { (try? db.writer.read { try Self.unread($0) }) ?? 0 }

    /// Marks messages read; with "delete after reading" on, removes them instead.
    func markRead(_ ids: [Int64]) async {
        guard !ids.isEmpty else { return }
        if deleteAfterRead {
            await delete(ids)
            return
        }
        try? await db.writer.write { [now = clock.now.timeIntervalSince1970] db in
            try db.execute(sql: "UPDATE inbox_messages SET read_at = ? WHERE read_at IS NULL AND id IN (\(Self.list(ids)))",
                           arguments: [now])
        }
        await updateBadge()
    }

    func markAllRead() async {
        let ids = all().filter { !$0.isRead }.map(\.id)
        await markRead(ids)
    }

    func markUnread(_ ids: [Int64]) async {
        try? await db.writer.write { db in
            try db.execute(sql: "UPDATE inbox_messages SET read_at = NULL WHERE id IN (\(Self.list(ids)))")
        }
        await updateBadge()
    }

    func delete(_ ids: [Int64]) async {
        guard !ids.isEmpty else { return }
        try? await db.writer.write { db in
            try db.execute(sql: "DELETE FROM inbox_messages WHERE id IN (\(Self.list(ids)))")
        }
        await updateBadge()
    }

    func deleteRead() async {
        try? await db.writer.write { db in try db.execute(sql: "DELETE FROM inbox_messages WHERE read_at IS NOT NULL") }
        await updateBadge()
    }

    func updateBadge() async {
        await center.setBadge(unreadCount())
    }

    private static func list(_ ids: [Int64]) -> String { ids.map(String.init).joined(separator: ",") }
}
