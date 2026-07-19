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

    /// Ordering for display purposes, most frequent first. The raw values are
    /// storage-only and NOT ordered by frequency (new cases were appended over
    /// time), so never sort by `rawValue`.
    var sortOrder: Int {
        switch self {
        case .daily: return 0
        case .weekdays: return 1
        case .weekends: return 2
        case .weekly: return 3
        case .biweekly: return 4
        case .monthly: return 5
        case .quarterly: return 6
        case .semiannually: return 7
        case .yearly: return 8
        case .none: return 9
        }
    }

    func nextDate(from date: Date, anchorDay: Int? = nil) -> Date? {
        let calendar = Calendar.current
        switch self {
        case .none:
            return nil
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: date)
        case .weekdays:
            // Find next weekday (Mon-Fri) - max 7 iterations to find next weekday
            guard var nextDate = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
            for _ in 0..<7 {
                if !calendar.isDateInWeekend(nextDate) { return nextDate }
                guard let next = calendar.date(byAdding: .day, value: 1, to: nextDate) else { return nil }
                nextDate = next
            }
            return nextDate
        case .weekends:
            // Find next weekend day (Sat or Sun) - max 7 iterations to find next weekend
            guard var nextDate = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
            for _ in 0..<7 {
                if calendar.isDateInWeekend(nextDate) { return nextDate }
                guard let next = calendar.date(byAdding: .day, value: 1, to: nextDate) else { return nil }
                nextDate = next
            }
            return nextDate
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case .biweekly:
            return calendar.date(byAdding: .weekOfYear, value: 2, to: date)
        case .monthly:
            return Self.addMonths(1, to: date, anchorDay: anchorDay)
        case .quarterly:
            return Self.addMonths(3, to: date, anchorDay: anchorDay)
        case .semiannually:
            return Self.addMonths(6, to: date, anchorDay: anchorDay)
        case .yearly:
            return Self.addMonths(12, to: date, anchorDay: anchorDay)
        }
    }

    /// Adds months, restoring the schedule's anchor day-of-month when a previous
    /// occurrence was clamped by a shorter month. Without an anchor, "monthly on
    /// the 31st" drifts permanently after February (Jan 31 → Feb 28 → Mar 28);
    /// with anchorDay = 31 it recovers (Jan 31 → Feb 28 → Mar 31).
    private static func addMonths(_ months: Int, to date: Date, anchorDay: Int?) -> Date? {
        let calendar = Calendar.current
        guard let advanced = calendar.date(byAdding: .month, value: months, to: date) else { return nil }
        guard let anchorDay, anchorDay > calendar.component(.day, from: advanced) else { return advanced }

        // Move the day up to the anchor, clamped to the target month's length.
        let daysInMonth = calendar.range(of: .day, in: .month, for: advanced)?.count
            ?? calendar.component(.day, from: advanced)
        var components = calendar.dateComponents([.year, .month, .hour, .minute, .second], from: advanced)
        components.day = min(anchorDay, daysInMonth)
        return calendar.date(from: components) ?? advanced
    }
}

enum ReminderPriority: Int, Codable, CaseIterable {
    case normal = 0
    case urgent = 3  // Keep rawValue 3 to match old "high" for existing data

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .urgent: return "Urgent"
        }
    }

    var icon: String? {
        switch self {
        case .normal: return nil
        case .urgent: return "exclamationmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .normal: return .gray
        case .urgent: return .red
        }
    }

    // Migration: map old values to new
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(Int.self)
        // Map old low(1), medium(2) to normal(0), high(3) stays as urgent(3)
        switch rawValue {
        case 3: self = .urgent
        default: self = .normal
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

    /// For recurring reminders: the id of the next occurrence spawned when this one
    /// was completed. Used to remove the orphan if the completion is later undone.
    var nextOccurrenceID: UUID?

    /// For month-based recurrences (monthly/quarterly/semiannually/yearly): the
    /// day-of-month the schedule is anchored to. Lets "monthly on the 31st"
    /// recover after being clamped to a shorter month (e.g. Feb 28) instead of
    /// drifting to the 28th forever. Nil for older data and non-month schedules.
    var recurrenceAnchorDay: Int?

    var category: Category?

    // Habit completion history - stores dates when habit was completed
    var habitCompletionDates: [Date] = []

    init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        dueDate: Date? = nil,
        priority: ReminderPriority = .normal,
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
        get { ReminderPriority(rawValue: priorityRaw) ?? .normal }
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
        // Prefer the stable marker; keep a name fallback so nothing breaks in the
        // window before the launch-time backfill (Category.backfillHabitMarker) runs.
        (category?.isHabitCategory ?? false) || category?.name == "Habits"
    }

    var isOverdue: Bool {
        // Habits are never overdue
        guard !isHabit else { return false }
        guard let dueDate = dueDate, !isCompleted else { return false }
        // Compare at day level - something due today is not overdue until tomorrow
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let due = calendar.startOfDay(for: dueDate)
        return due < today
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

    /// Days until due (negative if overdue, nil if no due date)
    var daysUntilDue: Int? {
        guard let dueDate = dueDate else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let due = calendar.startOfDay(for: dueDate)
        return calendar.dateComponents([.day], from: today, to: due).day
    }

    /// Returns true if this is a recurring item not due within the next few days
    var isDistantRecurring: Bool {
        guard isRecurring, let days = daysUntilDue else { return false }
        return days > 3
    }

    /// Human-readable "in X days" or "X days ago" string
    var daysUntilDueText: String? {
        guard let days = daysUntilDue else { return nil }
        if days == 0 { return "Today" }
        if days == 1 { return "Tomorrow" }
        if days == -1 { return "Yesterday" }
        if days > 1 { return "in \(days) days" }
        return "\(-days) days ago"
    }

    var formattedDueDate: String? {
        guard let dueDate = dueDate else { return nil }

        if isDueToday {
            return "Today"
        } else if isDueTomorrow {
            return "Tomorrow"
        } else if isOverdue {
            return "Overdue: \(dueDate.formatted(date: .abbreviated, time: .omitted))"
        } else {
            return dueDate.formatted(date: .abbreviated, time: .omitted)
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

    /// Complete a reminder, handling recurring logic automatically.
    /// For recurring reminders, creates the next occurrence before marking complete.
    func complete(in modelContext: ModelContext) {
        // Habits track per-day completion history and reset at midnight; they must
        // never be permanently completed (that would remove them from the habit
        // list forever). Route generic completion UI to the habit mechanism.
        if isHabit {
            markHabitDoneToday()
            return
        }

        // Guard against re-completing an already-completed reminder, which would
        // spawn a second next occurrence (data duplication).
        guard !isCompleted else { return }

        if isRecurring, let nextReminder = createNextOccurrence() {
            modelContext.insert(nextReminder)
            nextOccurrenceID = nextReminder.id
        }
        markCompleted()
    }

    /// Undo a completion. For recurring reminders, removes the next occurrence that
    /// was spawned by `complete(in:)` so toggling complete on/off doesn't accumulate
    /// duplicate future occurrences.
    func uncomplete(in modelContext: ModelContext) {
        if let spawnedID = nextOccurrenceID {
            let id = spawnedID
            var descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            // Only remove the spawned occurrence if it's still pristine (untouched
            // and not itself completed), so we never delete data the user has acted on.
            if let spawned = try? modelContext.fetch(descriptor).first,
               !spawned.isCompleted {
                modelContext.delete(spawned)
            }
            nextOccurrenceID = nil
        }
        markIncomplete()
    }

    // Cached set of completion day strings for O(1) lookups
    // Rebuilt lazily when habitCompletionDates changes
    @Transient private var _completionDayKeys: Set<String>?
    @Transient private var _completionDatesCount: Int = -1

    private var completionDayKeys: Set<String> {
        // Rebuild cache if array count changed (simple invalidation)
        if _completionDayKeys == nil || _completionDatesCount != habitCompletionDates.count {
            _completionDayKeys = Set(habitCompletionDates.map { Self.dayKey(for: $0) })
            _completionDatesCount = habitCompletionDates.count
        }
        return _completionDayKeys!
    }

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = Calendar.current.timeZone
        return f
    }()

    private static func dayKey(for date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    private func invalidateCompletionCache() {
        _completionDayKeys = nil
        _completionDatesCount = -1
    }

    /// For habits: just set completedAt without marking permanently complete
    /// The habit resets at midnight since isCompletedToday checks the date
    func markHabitDoneToday() {
        let today = Calendar.current.startOfDay(for: Date())
        completedAt = Date()

        // Add to history if not already completed today
        let key = Self.dayKey(for: today)
        if !completionDayKeys.contains(key) {
            habitCompletionDates.append(today)
            invalidateCompletionCache()
        }
    }

    /// For habits: clear today's completion
    func clearHabitCompletion() {
        completedAt = nil

        // Remove today from history
        let today = Calendar.current.startOfDay(for: Date())
        habitCompletionDates.removeAll { Calendar.current.isDate($0, inSameDayAs: today) }
        invalidateCompletionCache()
    }

    /// Check if habit was completed on a specific date — O(1) via cached Set
    func wasCompletedOn(date: Date) -> Bool {
        completionDayKeys.contains(Self.dayKey(for: date))
    }

    /// Get completion count for the last N days
    func completionCount(days: Int) -> Int {
        guard days > 0 else { return 0 }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -(days - 1), to: today) else {
            return 0
        }
        // Use cached set for fast counting
        var count = 0
        var date = startDate
        while date <= today {
            if completionDayKeys.contains(Self.dayKey(for: date)) {
                count += 1
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        return count
    }

    /// The day-of-month a month-based schedule is anchored to. Normally the due
    /// date's own day; the stored anchor is only trusted when the due date sits
    /// clamped at the end of a short month (e.g. due Feb 28 for a "monthly on the
    /// 31st" schedule), so a user editing the due date naturally resets the anchor.
    private func monthAnchorDay(for date: Date, calendar: Calendar) -> Int {
        let day = calendar.component(.day, from: date)
        guard let stored = recurrenceAnchorDay, stored > day,
              let range = calendar.range(of: .day, in: .month, for: date),
              day == range.count else {
            return day
        }
        return stored
    }

    /// For recurring reminders, creates the next occurrence and resets this one
    /// Returns a new Reminder if this is recurring, nil otherwise
    func createNextOccurrence() -> Reminder? {
        guard isRecurring, let currentDueDate = dueDate else { return nil }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Preserve the day-of-month anchor for month-based recurrences.
        let anchorDay: Int?
        switch recurrence {
        case .monthly, .quarterly, .semiannually, .yearly:
            anchorDay = monthAnchorDay(for: currentDueDate, calendar: calendar)
        default:
            anchorDay = nil
        }

        // Advance from the current due date — preserving the schedule's anchor
        // (day-of-week / day-of-month) — until the next occurrence is after today.
        // Completing an overdue item must neither re-base the whole schedule on the
        // completion date nor produce an occurrence that's immediately due again.
        guard var nextDueDate = recurrence.nextDate(from: currentDueDate, anchorDay: anchorDay) else { return nil }
        var iterations = 0
        while calendar.startOfDay(for: nextDueDate) <= today, iterations < 1000 {
            guard let advanced = recurrence.nextDate(from: nextDueDate, anchorDay: anchorDay) else { break }
            nextDueDate = advanced
            iterations += 1
        }
        // Safety net for absurdly overdue items (beyond the iteration cap):
        // fall back to advancing from today.
        if calendar.startOfDay(for: nextDueDate) <= today {
            nextDueDate = recurrence.nextDate(from: today, anchorDay: anchorDay) ?? nextDueDate
        }

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
        nextReminder.recurrenceAnchorDay = anchorDay

        return nextReminder
    }

    var formattedRecurrence: String? {
        guard isRecurring else { return nil }
        return recurrence.label
    }

    /// Detailed recurrence description including the specific day/date
    var detailedRecurrence: String? {
        guard isRecurring, let dueDate = dueDate else { return nil }

        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: dueDate)
        let dayOfMonth = monthAnchorDay(for: dueDate, calendar: calendar)
        let weekdayName = calendar.weekdaySymbols[weekday - 1]

        switch recurrence {
        case .none:
            return nil
        case .daily:
            return "Every day"
        case .weekdays:
            return "Every weekday (Mon-Fri)"
        case .weekends:
            return "Every weekend"
        case .weekly:
            return "Every \(weekdayName)"
        case .biweekly:
            return "Every other \(weekdayName)"
        case .monthly:
            return "Monthly on the \(ordinal(dayOfMonth))"
        case .quarterly:
            return "Every 3 months on the \(ordinal(dayOfMonth))"
        case .semiannually:
            return "Every 6 months on the \(ordinal(dayOfMonth))"
        case .yearly:
            let month = calendar.component(.month, from: dueDate)
            let monthName = calendar.monthSymbols[month - 1]
            return "Every year on \(monthName) \(dayOfMonth)"
        }
    }

    private func ordinal(_ n: Int) -> String {
        let suffix: String
        let ones = n % 10
        let tens = (n / 10) % 10

        if tens == 1 {
            suffix = "th"
        } else {
            switch ones {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(n)\(suffix)"
    }
}
