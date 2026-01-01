import SwiftUI
import SwiftData

enum RecurrenceType: Int, Codable, CaseIterable {
    case none = 0
    case daily = 1
    case weekdays = 7      // Mon-Fri
    case weekends = 8      // Sat-Sun
    case weekly = 2
    case biweekly = 3
    case monthly = 4
    case quarterly = 6     // 3 months
    case semiannually = 9  // 6 months
    case yearly = 5

    var label: String {
        switch self {
        case .none: return "None"
        case .daily: return "Daily"
        case .weekdays: return "Weekdays"
        case .weekends: return "Weekends"
        case .weekly: return "Weekly"
        case .biweekly: return "Every 2 Weeks"
        case .monthly: return "Monthly"
        case .quarterly: return "Every 3 Months"
        case .semiannually: return "Every 6 Months"
        case .yearly: return "Yearly"
        }
    }

    var icon: String {
        switch self {
        case .none: return "arrow.forward"
        case .daily: return "sun.max.fill"
        case .weekdays: return "briefcase.fill"
        case .weekends: return "figure.walk"
        case .weekly: return "calendar.badge.clock"
        case .biweekly: return "calendar.badge.plus"
        case .monthly: return "calendar"
        case .quarterly: return "calendar.badge.exclamationmark"
        case .semiannually: return "6.circle"
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
        case .weekdays:
            // Find next weekday (Mon-Fri)
            var nextDate = calendar.date(byAdding: .day, value: 1, to: date)!
            while calendar.isDateInWeekend(nextDate) {
                nextDate = calendar.date(byAdding: .day, value: 1, to: nextDate)!
            }
            return nextDate
        case .weekends:
            // Find next weekend day (Sat or Sun)
            var nextDate = calendar.date(byAdding: .day, value: 1, to: date)!
            while !calendar.isDateInWeekend(nextDate) {
                nextDate = calendar.date(byAdding: .day, value: 1, to: nextDate)!
            }
            return nextDate
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case .biweekly:
            return calendar.date(byAdding: .weekOfYear, value: 2, to: date)
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: date)
        case .quarterly:
            return calendar.date(byAdding: .month, value: 3, to: date)
        case .semiannually:
            return calendar.date(byAdding: .month, value: 6, to: date)
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
    var id: UUID = UUID()
    var title: String = ""
    var notes: String = ""
    var dueDate: Date?
    var priorityRaw: Int = 0
    var isCompleted: Bool = false
    var createdAt: Date = Date()
    var completedAt: Date?
    var aiEnhancedDescription: String?
    var appleSyncID: String?
    var hasBeenSynced: Bool = false
    var recurrenceRaw: Int = 0

    var category: Category?

    // Habit completion history - stores dates when habit was completed
    var habitCompletionDates: [Date] = []

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
        let today = Calendar.current.startOfDay(for: Date())
        completedAt = Date()

        // Add to history if not already completed today
        if !habitCompletionDates.contains(where: { Calendar.current.isDate($0, inSameDayAs: today) }) {
            habitCompletionDates.append(today)
        }
    }

    /// For habits: clear today's completion
    func clearHabitCompletion() {
        completedAt = nil

        // Remove today from history
        let today = Calendar.current.startOfDay(for: Date())
        habitCompletionDates.removeAll { Calendar.current.isDate($0, inSameDayAs: today) }
    }

    /// Check if habit was completed on a specific date
    func wasCompletedOn(date: Date) -> Bool {
        habitCompletionDates.contains { Calendar.current.isDate($0, inSameDayAs: date) }
    }

    /// Get completion count for the last N days
    func completionCount(days: Int) -> Int {
        let calendar = Calendar.current
        let startDate = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: Date()))!
        return habitCompletionDates.filter { $0 >= startDate }.count
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
