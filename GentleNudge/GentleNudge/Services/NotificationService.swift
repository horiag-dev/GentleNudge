import Foundation
import UserNotifications
import SwiftData
#if os(iOS)
import UIKit
#endif

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
            // Distinguish "never set" from a deliberately chosen midnight (hour 0).
            guard UserDefaults.standard.object(forKey: hourKey) != nil else {
                return 8 // Default to 8 AM
            }
            return UserDefaults.standard.integer(forKey: hourKey)
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

    /// Builds the morning notification content. When `aiBody` is non-empty it
    /// becomes the body (path (a): AI-prioritized, "important work first");
    /// otherwise the existing bullet list is used, so no-key / fallback behavior
    /// is byte-for-byte what it is today.
    func buildNotificationContent(
        needsAttentionCount: Int,
        topItems: [String],
        aiBody: String? = nil
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        if needsAttentionCount == 0 {
            content.title = "Good morning!"
            content.body = "Nothing on your plate today. Enjoy!"
        } else {
            content.title = "Good morning! \(needsAttentionCount) item\(needsAttentionCount == 1 ? "" : "s") today"

            let trimmedAI = aiBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedAI.isEmpty {
                // AI-prioritized body.
                content.body = trimmedAI
            } else if !topItems.isEmpty {
                // Bullet list fallback (unchanged existing behavior).
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

    func updateScheduledNotificationContent(
        needsAttentionCount: Int,
        topItems: [String],
        aiBody: String? = nil
    ) {
        guard isEnabled else { return }

        // Cancel and reschedule with updated content
        cancelMorningNotification()

        var dateComponents = DateComponents()
        dateComponents.hour = notificationHour
        dateComponents.minute = notificationMinute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)

        let content = buildNotificationContent(
            needsAttentionCount: needsAttentionCount,
            topItems: topItems,
            aiBody: aiBody
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

    #if os(iOS)
    // MARK: - AI-prioritized morning notification (path a)

    /// Cached AI notification body, keyed so a later reschedule can reuse it.
    private static let aiBodyKey = "morningBriefingNotificationBody"
    private static let aiBodyDayKey = "morningBriefingNotificationBodyDay"

    /// Pre-generates the AI-prioritized notification body during the iOS
    /// background window and reschedules the morning notification with it.
    ///
    /// Reliability contract:
    /// 1. The **non-AI fallback is scheduled immediately** (synchronously) so the
    ///    notification is never empty or worse than today, regardless of what the
    ///    AI call does.
    /// 2. The AI generation runs inside a `beginBackgroundTask` / `endBackgroundTask`
    ///    window so iOS grants time for the request to finish after backgrounding.
    /// 3. Any failure — no key, no candidates, network error, the service's own
    ///    ~10s timeout, or the OS expiring the background task — leaves the
    ///    fallback in place.
    ///
    /// `reminders` are lightweight main-actor snapshots (all reminders); the
    /// service selects tomorrow's overdue/due-today/upcoming set itself.
    func preGenerateAndScheduleMorningNotification(
        needsAttentionCount: Int,
        topItems: [String],
        reminders: [MorningBriefingService.ReminderSummary]
    ) {
        guard isEnabled else { return }

        // (1) Always schedule the non-AI fallback first.
        updateScheduledNotificationContent(needsAttentionCount: needsAttentionCount, topItems: topItems)

        // Only attempt AI when there's a key and something to prioritize.
        guard Constants.isAPIKeyConfigured, needsAttentionCount > 0 else { return }

        // The notification fires TOMORROW morning, so prioritize against tomorrow.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let tomorrow = calendar.date(
            byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())
        ) else { return }

        let candidates = MorningBriefingService.selectCandidates(
            from: reminders,
            referenceDate: tomorrow,
            calendar: calendar
        )
        guard !candidates.isEmpty else { return }

        // (2) Guard the network call with a background-task window.
        let application = UIApplication.shared
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = application.beginBackgroundTask(withName: "MorningBriefingGeneration") {
            // Expiration handler: OS is reclaiming time. Fallback is already scheduled.
            application.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        guard backgroundTaskID != .invalid else { return } // no background time granted

        let service = MorningBriefingService()
        Task { @MainActor in
            defer {
                if backgroundTaskID != .invalid {
                    application.endBackgroundTask(backgroundTaskID)
                    backgroundTaskID = .invalid
                }
            }
            let briefing = await service.generate(
                candidates: candidates,
                referenceDate: tomorrow,
                calendar: calendar,
                timeZone: calendar.timeZone
            )
            // Re-check enabled: the user could have toggled off while generating.
            guard let briefing, self.isEnabled else { return }

            UserDefaults.standard.set(briefing.notificationBody, forKey: Self.aiBodyKey)
            UserDefaults.standard.set(
                Self.dayKey(for: tomorrow, calendar: calendar),
                forKey: Self.aiBodyDayKey
            )
            self.updateScheduledNotificationContent(
                needsAttentionCount: needsAttentionCount,
                topItems: topItems,
                aiBody: briefing.notificationBody
            )
        }
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }
    #endif
}
