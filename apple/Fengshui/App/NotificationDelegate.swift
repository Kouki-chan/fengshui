import UIKit
import UserNotifications

/// Records deliveries (willPresent / taps) and dismissals for the delay measurement (spec §11).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    nonisolated(unsafe) static var scheduler: WindDownScheduler?
    static let category = "wind_down"

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        // customDismissAction: we hear about "dismissed", so the Home-arrival prompt isn't repeated.
        c.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [], intentIdentifiers: [],
                                                            options: [.customDismissAction])])
        return true
    }

    // Completion-handler variants: UNNotification isn't Sendable, so plain values are extracted first.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                            withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        let id = n.request.identifier, date = n.date
        Task { await Self.scheduler?.markDelivered(id, at: date) }
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
        }
        completion()
    }
}
