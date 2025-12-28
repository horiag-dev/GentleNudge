import Foundation
import EventKit

actor AppleRemindersService {
    static let shared = AppleRemindersService()

    private let eventStore = EKEventStore()
    private var backupList: EKCalendar?

    private init() {}

    enum SyncError: LocalizedError {
        case accessDenied
        case listNotFound
        case syncFailed(Error)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "Access to Reminders was denied. Please grant access in Settings."
            case .listNotFound:
                return "Could not find or create the backup reminders list."
            case .syncFailed(let error):
                return "Sync failed: \(error.localizedDescription)"
            }
        }
    }

    enum AuthorizationStatus {
        case authorized
        case denied
        case notDetermined
    }

    func checkAuthorizationStatus() -> AuthorizationStatus {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .authorized:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .notDetermined, .writeOnly:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    func requestAccess() async throws -> Bool {
        if #available(iOS 17.0, *) {
            return try await eventStore.requestFullAccessToReminders()
        } else {
            return try await eventStore.requestAccess(to: .reminder)
        }
    }

    private func getOrCreateBackupList() throws -> EKCalendar {
        if let existing = backupList {
            return existing
        }

        // Look for existing list
        let calendars = eventStore.calendars(for: .reminder)
        if let existing = calendars.first(where: { $0.title == Constants.appleRemindersListName }) {
            backupList = existing
            return existing
        }

        // Create new list
        let newList = EKCalendar(for: .reminder, eventStore: eventStore)
        newList.title = Constants.appleRemindersListName

        // Find a suitable source
        if let localSource = eventStore.sources.first(where: { $0.sourceType == .local }) {
            newList.source = localSource
        } else if let iCloudSource = eventStore.sources.first(where: { $0.sourceType == .calDAV }) {
            newList.source = iCloudSource
        } else if let anySource = eventStore.sources.first {
            newList.source = anySource
        } else {
            throw SyncError.listNotFound
        }

        try eventStore.saveCalendar(newList, commit: true)
        backupList = newList
        return newList
    }

    func syncReminder(_ reminder: Reminder) async throws {
        let status = checkAuthorizationStatus()
        guard status == .authorized else {
            throw SyncError.accessDenied
        }

        let list = try getOrCreateBackupList()

        // Check if reminder already exists in Apple Reminders
        if let syncID = reminder.appleSyncID,
           let existingReminder = eventStore.calendarItem(withIdentifier: syncID) as? EKReminder {
            // Update existing reminder
            existingReminder.title = reminder.title
            existingReminder.notes = buildNotes(for: reminder)
            existingReminder.isCompleted = reminder.isCompleted
            existingReminder.priority = mapPriority(reminder.priority)

            if let dueDate = reminder.dueDate {
                existingReminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: dueDate
                )
            } else {
                existingReminder.dueDateComponents = nil
            }

            try eventStore.save(existingReminder, commit: true)
        } else {
            // Create new reminder
            let ekReminder = EKReminder(eventStore: eventStore)
            ekReminder.title = reminder.title
            ekReminder.notes = buildNotes(for: reminder)
            ekReminder.isCompleted = reminder.isCompleted
            ekReminder.priority = mapPriority(reminder.priority)
            ekReminder.calendar = list

            if let dueDate = reminder.dueDate {
                ekReminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: dueDate
                )
            }

            try eventStore.save(ekReminder, commit: true)

            // Store the sync ID back (needs to be done on main actor/context)
            // This is handled by the caller
        }
    }

    func syncAllReminders(_ reminders: [Reminder]) async throws -> [String: String] {
        let status = checkAuthorizationStatus()
        guard status == .authorized else {
            throw SyncError.accessDenied
        }

        let list = try getOrCreateBackupList()
        var syncMapping: [String: String] = [:]

        for reminder in reminders {
            let ekReminder = EKReminder(eventStore: eventStore)
            ekReminder.title = reminder.title
            ekReminder.notes = buildNotes(for: reminder)
            ekReminder.isCompleted = reminder.isCompleted
            ekReminder.priority = mapPriority(reminder.priority)
            ekReminder.calendar = list

            if let dueDate = reminder.dueDate {
                ekReminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: dueDate
                )
            }

            try eventStore.save(ekReminder, commit: false)
            syncMapping[reminder.id.uuidString] = ekReminder.calendarItemIdentifier
        }

        try eventStore.commit()
        return syncMapping
    }

    func deleteReminder(syncID: String) async throws {
        guard let ekReminder = eventStore.calendarItem(withIdentifier: syncID) as? EKReminder else {
            return
        }
        try eventStore.remove(ekReminder, commit: true)
    }

    // MARK: - Import from Apple Reminders

    struct ImportedReminder: Sendable {
        let title: String
        let notes: String
        let dueDate: Date?
        let isCompleted: Bool
        let priority: ReminderPriority
        let listName: String
    }

    func fetchAllReminders() async throws -> [ImportedReminder] {
        let status = checkAuthorizationStatus()
        guard status == .authorized else {
            throw SyncError.accessDenied
        }

        let calendars = eventStore.calendars(for: .reminder)
        var allReminders: [ImportedReminder] = []

        for calendar in calendars {
            // Skip our own backup list
            if calendar.title == Constants.appleRemindersListName {
                continue
            }

            let predicate = eventStore.predicateForReminders(in: [calendar])
            let ekReminders = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[EKReminder], Error>) in
                eventStore.fetchReminders(matching: predicate) { reminders in
                    continuation.resume(returning: reminders ?? [])
                }
            }

            for ekReminder in ekReminders {
                let imported = ImportedReminder(
                    title: ekReminder.title ?? "Untitled",
                    notes: ekReminder.notes ?? "",
                    dueDate: ekReminder.dueDateComponents?.date,
                    isCompleted: ekReminder.isCompleted,
                    priority: mapFromEKPriority(ekReminder.priority),
                    listName: calendar.title
                )
                allReminders.append(imported)
            }
        }

        return allReminders
    }

    func getAvailableLists() -> [String] {
        let calendars = eventStore.calendars(for: .reminder)
        return calendars
            .filter { $0.title != Constants.appleRemindersListName }
            .map { $0.title }
    }

    private func mapFromEKPriority(_ priority: Int) -> ReminderPriority {
        switch priority {
        case 1...4: return .high
        case 5: return .medium
        case 6...9: return .low
        default: return .none
        }
    }

    private func buildNotes(for reminder: Reminder) -> String {
        var notes = reminder.notes

        if let category = reminder.category {
            notes += "\n\n[Category: \(category.name)]"
        }

        if let aiDescription = reminder.aiEnhancedDescription {
            notes += "\n\n[AI Context: \(aiDescription)]"
        }

        return notes
    }

    private func mapPriority(_ priority: ReminderPriority) -> Int {
        switch priority {
        case .none: return 0
        case .low: return 9
        case .medium: return 5
        case .high: return 1
        }
    }
}
