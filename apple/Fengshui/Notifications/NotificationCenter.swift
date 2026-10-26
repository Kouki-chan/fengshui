import Foundation
import UserNotifications

struct LocalNotification: Sendable, Equatable {
    var identifier: String
    var title: String
    var body: String
    /// nil = deliver now.
    var fireDate: Date?
    var userInfo: [String: String] = [:]
}

/// A delivered notification's content, for the in-app inbox.
struct DeliveredNotification: Sendable, Equatable {
    var identifier: String
    var date: Date
    var title: String
    var body: String
    var kind: String?
}

struct PendingNotification: Sendable, Equatable {
    var identifier: String
    var fireDate: Date?
}

/// UNUserNotificationCenter behind a protocol (spec §14.1). All notifications are local.
protocol NotificationCenter: Sendable {
    func requestAuthorization() async -> Bool
    func add(_ n: LocalNotification, timeZone: TimeZone) async throws
    func removePending(_ identifiers: [String]) async
    func pending() async -> [PendingNotification]
    /// Delivered notifications still in Notification Center, with their delivery dates.
    func delivered() async -> [(identifier: String, date: Date)]
    func deliveredContent() async -> [DeliveredNotification]
    /// The app icon's badge (unread inbox messages).
    func setBadge(_ count: Int) async
}

final class SystemNotificationCenter: NotificationCenter, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func isAuthorized() async -> Bool {
        await center.notificationSettings().authorizationStatus == .authorized
    }

    func add(_ n: LocalNotification, timeZone: TimeZone) async throws {
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.body
        content.sound = .default
        content.userInfo = n.userInfo
        content.categoryIdentifier = n.userInfo["kind"] == nil || n.userInfo["kind"] == "wind_down" ? "wind_down" : ""
        let trigger: UNNotificationTrigger?
        if let date = n.fireDate {
            // Calendar trigger at the exact local time: this is what keeps delivery within the
            // 5-minute target regardless of background execution (spec §11).
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            var comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            comps.timeZone = timeZone
            trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        } else {
            trigger = nil
        }
        try await center.add(UNNotificationRequest(identifier: n.identifier, content: content, trigger: trigger))
    }

    func removePending(_ identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func pending() async -> [PendingNotification] {
        await center.pendingNotificationRequests().map {
            PendingNotification(identifier: $0.identifier,
                                fireDate: ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate())
        }
    }

    func delivered() async -> [(identifier: String, date: Date)] {
        await center.deliveredNotifications().map { ($0.request.identifier, $0.date) }
    }

    func deliveredContent() async -> [DeliveredNotification] {
        await center.deliveredNotifications().map {
            let c = $0.request.content
            // Remote monitor alerts carry the server's alert id: file them under the same identifier the
            // monitor client uses, so one alert is one inbox message.
            let alertID = (c.userInfo["alert_id"] as? NSNumber)?.stringValue ?? c.userInfo["alert_id"] as? String
            return DeliveredNotification(identifier: alertID.map { "monitor-\($0)" } ?? $0.request.identifier, date: $0.date,
                                         title: c.title, body: c.body,
                                         kind: (c.userInfo["kind"] as? String) ?? (c.userInfo["fs"] as? String))
        }
    }

    func setBadge(_ count: Int) async {
        try? await center.setBadgeCount(count)
    }
}

final class FakeNotificationCenter: NotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [String: LocalNotification] = [:]
    private(set) var added: [LocalNotification] = []
    private(set) var removed: [String] = []
    var deliveredItems: [(identifier: String, date: Date)] = []
    var authorized = true
    private(set) var badge = 0

    func requestAuthorization() async -> Bool { authorized }

    func add(_ n: LocalNotification, timeZone: TimeZone) async throws {
        lock.withLock {
            requests[n.identifier] = n
            added.append(n)
        }
    }

    func removePending(_ identifiers: [String]) async {
        lock.withLock {
            for id in identifiers { requests[id] = nil }
            removed += identifiers
        }
    }

    func pending() async -> [PendingNotification] {
        lock.withLock { requests.values.filter { $0.fireDate != nil }.map { PendingNotification(identifier: $0.identifier, fireDate: $0.fireDate) } }
    }

    func delivered() async -> [(identifier: String, date: Date)] { lock.withLock { deliveredItems } }

    func deliveredContent() async -> [DeliveredNotification] {
        lock.withLock {
            deliveredItems.compactMap { d in
                added.last { $0.identifier == d.identifier }.map {
                    DeliveredNotification(identifier: d.identifier, date: d.date, title: $0.title, body: $0.body,
                                          kind: $0.userInfo["kind"])
                }
            }
        }
    }

    func setBadge(_ count: Int) async { lock.withLock { badge = count } }

    /// Simulates the system delivering a pending notification.
    func deliver(_ id: String, at date: Date) {
        lock.withLock {
            requests[id] = nil
            deliveredItems.append((id, date))
        }
    }
}
