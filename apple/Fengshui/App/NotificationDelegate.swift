import UIKit
import UserNotifications

/// Records deliveries (willPresent / taps) and dismissals for the delay measurement (spec §11).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    nonisolated(unsafe) static var scheduler: WindDownScheduler?
    nonisolated(unsafe) static var monitor: MonitorClient?
    nonisolated(unsafe) static var inbox: InboxStore?
    nonisolated(unsafe) static var registerForPush = false
    static let category = "wind_down"

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        // customDismissAction: we hear about "dismissed", so the Home-arrival prompt isn't repeated.
        c.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [], intentIdentifiers: [],
                                                            options: [.customDismissAction])])
        // Works only with the paid account's aps-environment entitlement; the failure is shown in
        // Settings → Health monitor (DECISIONS D-19).
        if Self.registerForPush { application.registerForRemoteNotifications() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        Task { await Self.monitor?.setPushToken(hex, error: nil) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        let msg = error.localizedDescription
        Task { await Self.monitor?.setPushToken(nil, error: msg) }
    }

    /// Silent push from the monitor: send readings now. Alert pushes are filed in the inbox.
    func application(_ application: UIApplication, didReceiveRemoteNotification info: [AnyHashable: Any]) async
        -> UIBackgroundFetchResult {
        let kind = info["fs"] as? String
        guard let monitor = Self.monitor else { return .noData }
        if kind == "monitor_request" { return await monitor.respondToPush() ? .newData : .failed }
        if kind == "monitor_alert" { await monitor.pullAlerts(); return .newData }
        return .noData
    }

    // Completion-handler variants: UNNotification isn't Sendable, so plain values are extracted first.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                            withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        let id = n.request.identifier, date = n.date
        Task {
            await Self.scheduler?.markDelivered(id, at: date)
            await Self.inbox?.ingestDelivered()
        }
        completion([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                            withCompletionHandler completion: @escaping () -> Void) {
        let id = r.notification.request.identifier, date = r.notification.date
        let dismissed = r.actionIdentifier == UNNotificationDismissActionIdentifier
        let night = r.notification.request.content.userInfo["night_of"] as? String
        Task {
            await Self.scheduler?.markDelivered(id, at: date)
            if dismissed, let night { await Self.scheduler?.dismissTonight(night) }
            await Self.inbox?.ingestDelivered()
        }
        completion()
    }
}
