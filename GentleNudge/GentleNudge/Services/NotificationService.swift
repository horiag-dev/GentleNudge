import Foundation
import UserNotifications
import SwiftData

class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    // Show notifications even when app is in foreground
    // .list ensures notifications persist in notification center after dismissal
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge, .list])
    }

    // Handle notification tap - opens the app
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // App opens automatically, just complete
        completionHandler()
    }
}

@MainActor
class NotificationService {
    static let shared = NotificationService()

    private let notificationCenter = UNUserNotificationCenter.current()
    private let morningNotificationID = "morning-needs-attention"
    private let delegate = NotificationDelegate()

    init() {
        notificationCenter.delegate = delegate
    }

    // UserDefaults keys
    private let enabledKey = "morningNotificationEnabled"
    private let hourKey = "morningNotificationHour"
    private let minuteKey = "morningNotificationMinute"

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue {
                scheduleMorningNotification()
            } else {
                cancelMorningNotification()
            }
        }
    }

    var notificationHour: Int {
        get {
            let hour = UserDefaults.standard.integer(forKey: hourKey)
            return hour == 0 ? 8 : hour // Default to 8 AM
        }
        set {
            UserDefaults.standard.set(newValue, forKey: hourKey)
            if isEnabled { scheduleMorningNotification() }
        }
    }

    var notificationMinute: Int {
        get { UserDefaults.standard.integer(forKey: minuteKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: minuteKey)
            if isEnabled { scheduleMorningNotification() }
        }
    }

    var notificationTime: Date {
        get {
            var components = DateComponents()
            components.hour = notificationHour
            components.minute = notificationMinute
            return Calendar.current.date(from: components) ?? Date()
        }
        set {
            let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            notificationHour = components.hour ?? 8
            notificationMinute = components.minute ?? 0
        }
    }

    // MARK: - Permission

    func requestPermission() async -> Bool {
        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
            return granted
        } catch {
            print("Notification permission error: \(error)")
            return false
        }
    }

    func checkPermissionStatus() async -> UNAuthorizationStatus {
        let settings = await notificationCenter.notificationSettings()
        return settings.authorizationStatus
    }

    // MARK: - Scheduling

    func scheduleMorningNotification() {
        // Remove existing notification first
        cancelMorningNotification()

        // Create trigger for daily at specified time
        var dateComponents = DateComponents()
        dateComponents.hour = notificationHour
        dateComponents.minute = notificationMinute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)

        // Create content (will be updated when notification fires)
        let content = UNMutableNotificationContent()
        content.title = "Good Morning!"
        content.body = "Checking your reminders..."
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: morningNotificationID,
            content: content,
            trigger: trigger
        )

        notificationCenter.add(request) { error in
            if let error = error {
                print("Failed to schedule morning notification: \(error)")
            } else {
                print("Morning notification scheduled for \(self.notificationHour):\(String(format: "%02d", self.notificationMinute))")
            }
        }
    }

    func cancelMorningNotification() {
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [morningNotificationID])
    }

    // MARK: - Test / Trigger

    func triggerTestNotification(needsAttentionCount: Int, topItems: [String]) async {
        let status = await checkPermissionStatus()
        guard status == .authorized else {
            print("Notifications not authorized")
            return
        }

        let content = buildNotificationContent(
            needsAttentionCount: needsAttentionCount,
            topItems: topItems
        )

        // Trigger in 0.5 seconds for testing
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)

        let request = UNNotificationRequest(
            identifier: "test-notification-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )

        do {
            try await notificationCenter.add(request)
            print("Test notification scheduled")
        } catch {
            print("Failed to schedule test notification: \(error)")
        }
    }

    func buildNotificationContent(needsAttentionCount: Int, topItems: [String]) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        if needsAttentionCount == 0 {
            content.title = "Good morning!"
            content.body = "Nothing on your plate today. Enjoy!"
        } else {
            content.title = "Good morning! \(needsAttentionCount) item\(needsAttentionCount == 1 ? "" : "s") today"

            // Bullet list format
            if !topItems.isEmpty {
                let bulletList = topItems.prefix(5).map { "• \($0)" }.joined(separator: "\n")
                content.body = bulletList
            }
        }

        content.badge = NSNumber(value: needsAttentionCount)
        return content
    }

    // MARK: - Badge Management

    /// Updates the app badge count independently of notifications
    /// Call this when app becomes active or when reminder data changes
    func updateBadgeCount(_ count: Int) async {
        let status = await checkPermissionStatus()
        guard status == .authorized else { return }

        do {
            try await notificationCenter.setBadgeCount(count)
        } catch {
            print("Failed to update badge count: \(error)")
        }
    }

    /// Clears the app badge
    func clearBadge() async {
        await updateBadgeCount(0)
    }

    // MARK: - Update scheduled notification content

    func updateScheduledNotificationContent(needsAttentionCount: Int, topItems: [String]) {
        guard isEnabled else { return }

        // Cancel and reschedule with updated content
        cancelMorningNotification()

        var dateComponents = DateComponents()
        dateComponents.hour = notificationHour
        dateComponents.minute = notificationMinute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)

        let content = buildNotificationContent(
            needsAttentionCount: needsAttentionCount,
            topItems: topItems
        )

        let request = UNNotificationRequest(
            identifier: morningNotificationID,
            content: content,
            trigger: trigger
        )

        notificationCenter.add(request) { error in
            if let error = error {
                print("Failed to update morning notification: \(error)")
            }
        }
    }
}
