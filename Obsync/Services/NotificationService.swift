import Foundation
import UserNotifications

/// Sends macOS notifications for sync events (errors, first sync, etc.)
class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                return
            case .denied:
                debugLog("[Notifications] Permission denied in system settings")
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let nsError = error as NSError? {
                        if nsError.domain == UNErrorDomain && nsError.code == 1 {
                            debugLog("[Notifications] Notifications are not allowed for this application")
                            return
                        }
                        debugLog("[Notifications] Permission request failed: \(nsError.localizedDescription)")
                        return
                    }
                    if !granted {
                        debugLog("[Notifications] Permission was not granted")
                    }
                }
            @unknown default:
                return
            }
        }
    }

    func sendNotification(title: String, body: String, category: NotificationCategory) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category.rawValue

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let nsError = error as NSError? {
                if nsError.domain == UNErrorDomain && nsError.code == 1 {
                    return
                }
                debugLog("[Notifications] Failed to schedule notification: \(nsError.localizedDescription)")
            }
        }
    }

    // Show notifications even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    enum NotificationCategory: String {
        case syncError
        case syncComplete
        case permissionIssue
    }
}
