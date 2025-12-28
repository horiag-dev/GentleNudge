import SwiftUI
import SwiftData

enum RecurrenceType: Int, Codable, CaseIterable {
    case none = 0
    case daily = 1
    case weekly = 2
    case biweekly = 3
    case monthly = 4
    case yearly = 5

    var label: String {
        switch self {
        case .none: return "None"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .biweekly: return "Every 2 Weeks"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }

    var icon: String {
        switch self {
        case .none: return "arrow.forward"
        case .daily: return "sun.max.fill"
        case .weekly: return "calendar.badge.clock"
        case .biweekly: return "calendar.badge.plus"
        case .monthly: return "calendar"
        case .yearly: return "calendar.circle"
        }
    }

    func nextDate(from date: Date) -> Date? {
        let calendar = Calendar.current
        switch self {
        case .none:
            return nil
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: date)
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case .biweekly:
            return calendar.date(byAdding: .weekOfYear, value: 2, to: date)
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: date)
        case .yearly:
            return calendar.date(byAdding: .year, value: 1, to: date)
        }
    }
}

enum ReminderPriority: Int, Codable, CaseIterable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3

    var label: String {
        switch self {
        case .none: return "None"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var icon: String? {
        switch self {
        case .none: return nil
        case .low: return "exclamationmark"
        case .medium: return "exclamationmark.2"
        case .high: return "exclamationmark.3"
        }
    }

    var color: Color {
        switch self {
        case .none: return .gray
        case .low: return .blue
        case .medium: return .orange
        case .high: return .red
        }
    }
}

@Model
final class Reminder {
    var id: UUID
    var title: String
    var notes: String
    var dueDate: Date?
    var priorityRaw: Int
    var isCompleted: Bool
    var createdAt: Date
    var completedAt: Date?
    var aiEnhancedDescription: String?
    var appleSyncID: String?
    var hasBeenSynced: Bool
    var recurrenceRaw: Int = 0

    var category: Category?

    init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        dueDate: Date? = nil,
        priority: ReminderPriority = .none,
        isCompleted: Bool = false,
        category: Category? = nil,
        recurrence: RecurrenceType = .none
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.priorityRaw = priority.rawValue
        self.isCompleted = isCompleted
        self.createdAt = Date()
        self.category = category
        self.hasBeenSynced = false
        self.recurrenceRaw = recurrence.rawValue
    }

    var priority: ReminderPriority {
        get { ReminderPriority(rawValue: priorityRaw) ?? .none }
        set { priorityRaw = newValue.rawValue }
    }

    var recurrence: RecurrenceType {
        get { RecurrenceType(rawValue: recurrenceRaw) ?? .none }
        set { recurrenceRaw = newValue.rawValue }
    }

    var isRecurring: Bool {
        recurrence != .none
    }

    var isHabit: Bool {
        category?.name == "Habits"
    }

    var isOverdue: Bool {
        // Habits are never overdue
        guard !isHabit else { return false }
        guard let dueDate = dueDate, !isCompleted else { return false }
        return dueDate < Date()
    }

    var isDueToday: Bool {
        guard let dueDate = dueDate else { return false }
        return Calendar.current.isDateInToday(dueDate)
    }

    var isCompletedToday: Bool {
        guard let completedAt = completedAt else { return false }
        return Calendar.current.isDateInToday(completedAt)
    }

    var isDueTomorrow: Bool {
        guard let dueDate = dueDate else { return false }
        return Calendar.current.isDateInTomorrow(dueDate)
    }

    var formattedDueDate: String? {
        guard let dueDate = dueDate else { return nil }

        if isDueToday {
            return "Today, \(dueDate.formatted(date: .omitted, time: .shortened))"
        } else if isDueTomorrow {
            return "Tomorrow, \(dueDate.formatted(date: .omitted, time: .shortened))"
        } else if isOverdue {
            return "Overdue: \(dueDate.formatted(date: .abbreviated, time: .shortened))"
        } else {
            return dueDate.formatted(date: .abbreviated, time: .shortened)
        }
    }

    func markCompleted() {
        isCompleted = true
        completedAt = Date()
    }

    func markIncomplete() {
        isCompleted = false
        completedAt = nil
    }

    /// For habits: just set completedAt without marking permanently complete
    /// The habit resets at midnight since isCompletedToday checks the date
    func markHabitDoneToday() {
        completedAt = Date()
    }

    /// For habits: clear today's completion
    func clearHabitCompletion() {
        completedAt = nil
    }

    /// For recurring reminders, creates the next occurrence and resets this one
    /// Returns a new Reminder if this is recurring, nil otherwise
    func createNextOccurrence() -> Reminder? {
        guard isRecurring, let currentDueDate = dueDate else { return nil }

        guard let nextDueDate = recurrence.nextDate(from: currentDueDate) else { return nil }

        let nextReminder = Reminder(
            title: title,
            notes: notes,
            dueDate: nextDueDate,
            priority: priority,
            isCompleted: false,
            category: category,
            recurrence: recurrence
        )
        nextReminder.aiEnhancedDescription = aiEnhancedDescription

        return nextReminder
    }

    var formattedRecurrence: String? {
        guard isRecurring else { return nil }
        return recurrence.label
    }
}
