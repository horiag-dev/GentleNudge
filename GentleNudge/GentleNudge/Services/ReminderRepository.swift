import Foundation
import SwiftData

/// Result of a repository executor: the `tool_result` payload plus display
/// fields the coordinator uses to build a card. `content` is a compact JSON
/// string on success, or a specific human-readable reason on error (self-healing
/// — the model reads it and re-tries or asks).
struct RepositoryToolResult: Sendable {
    let content: String
    let isError: Bool
    let reminderID: UUID?
    let displayTitle: String?
    let displaySummary: String?

    static func failure(_ message: String) -> RepositoryToolResult {
        RepositoryToolResult(
            content: message,
            isError: true,
            reminderID: nil,
            displayTitle: nil,
            displaySummary: nil
        )
    }
}

/// A dedicated persistence actor with its **own** `ModelContext` over the shared
/// `ModelContainer` (never the autosaving main context). UUIDs cross the actor
/// boundary; `@Model` instances never do — categories are re-fetched here and the
/// created reminder's id is returned out.
@ModelActor
actor ReminderRepository {

    // MARK: create_reminder

    func createReminder(_ input: CreateReminderInput, timeZone: TimeZone) -> RepositoryToolResult {
        // Resolve the cadence (enum string → RecurrenceType).
        guard let recurrence = RecurrenceType.fromToolValue(input.recurrence) else {
            return .failure(
                "Unknown recurrence '\(input.recurrence)'. Supported: \(ChatTools.recurrenceValues.joined(separator: ", "))."
            )
        }

        // Resolve the category by UUID in this context.
        guard let categoryUUID = UUID(uuidString: input.categoryID) else {
            return .failure(
                "Invalid category_id '\(input.categoryID)'. It must be a UUID from the provided category list. \(validCategoriesText())"
            )
        }
        let category: Category
        do {
            var descriptor = FetchDescriptor<Category>(predicate: #Predicate { $0.id == categoryUUID })
            descriptor.fetchLimit = 2
            let matches = try modelContext.fetch(descriptor)
            if matches.isEmpty {
                return .failure("Unknown category \(input.categoryID). \(validCategoriesText())")
            }
            guard matches.count == 1, let match = matches.first else {
                return .failure(
                    "Ambiguous category \(input.categoryID) (more than one match). \(validCategoriesText())"
                )
            }
            category = match
        } catch {
            return .failure("Couldn't look up the category: \(error.localizedDescription)")
        }

        // Parse the due date with a non-lenient formatter pinned to a frozen
        // Gregorian calendar + fixed timezone, requiring an exact round-trip.
        var dueDate: Date?
        if let raw = input.dueDate, !raw.isEmpty {
            guard let parsed = Self.parseDate(raw, timeZone: timeZone) else {
                return .failure("Invalid due_date '\(raw)'. Use a real calendar date in YYYY-MM-DD format.")
            }
            dueDate = parsed
        }

        // Cross-field validation strict mode can't express.
        if recurrence != .none, dueDate == nil {
            return .failure(
                "A recurring reminder needs a due_date for its first occurrence. Provide due_date (YYYY-MM-DD) for the \(input.recurrence) schedule."
            )
        }

        var anchorDay: Int?
        if recurrence.isMonthBased, let candidate = input.recurrenceAnchorDay {
            guard (1...31).contains(candidate) else {
                return .failure("recurrence_anchor_day must be between 1 and 31.")
            }
            if let due = dueDate {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = timeZone
                let dueDay = calendar.component(.day, from: due)
                let expected = Self.expectedAnchoredDay(anchorDay: candidate, dueDate: due, timeZone: timeZone)
                if dueDay != expected {
                    return .failure(
                        "For a \(input.recurrence) schedule anchored to day \(candidate), the first due_date must fall on day \(expected) of its month, but it falls on day \(dueDay). Adjust due_date or recurrence_anchor_day."
                    )
                }
            }
            anchorDay = candidate
        }
        // Anchor is ignored for non-month-based cadences (left nil).

        let priority: ReminderPriority = (input.priority == "urgent") ? .urgent : .normal

        let reminder = Reminder(
            title: input.title,
            notes: input.notes ?? "",
            dueDate: dueDate,
            priority: priority,
            category: category,
            recurrence: recurrence
        )
        // recurrenceAnchorDay is not an init argument — assign after construction.
        reminder.recurrenceAnchorDay = anchorDay

        modelContext.insert(reminder)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            return .failure("Couldn't save the reminder: \(error.localizedDescription)")
        }

        let dueString = dueDate.map { Self.dateString($0, timeZone: timeZone) }
        let recurrenceDescription: String? = reminder.isRecurring
            ? (reminder.detailedRecurrence ?? reminder.recurrence.label)
            : nil

        let payload = CreateReminderSuccess(
            id: reminder.id.uuidString,
            title: reminder.title,
            due_date: dueString,
            category: category.name,
            recurrence_description: recurrenceDescription
        )
        let content = Self.encodeJSON(payload) ?? "{\"id\":\"\(reminder.id.uuidString)\"}"
        let summary = Self.cardSummary(
            dueString: dueString,
            category: category.name,
            recurrence: recurrenceDescription,
            priority: priority
        )
        return RepositoryToolResult(
            content: content,
            isError: false,
            reminderID: reminder.id,
            displayTitle: reminder.title,
            displaySummary: summary
        )
    }

    // MARK: create_category (called only after the coordinator's approval gate)

    func createCategory(_ input: CreateCategoryInput) -> RepositoryToolResult {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure("A category name cannot be empty.") }

        let icon: String = {
            if let icon = input.icon, !icon.isEmpty { return icon }
            return "folder.fill"
        }()
        let color: String = {
            if let color = input.color, Category.availableColors.contains(color) { return color }
            return "gray"
        }()

        var sortOrder = 0
        if let existing = try? modelContext.fetch(FetchDescriptor<Category>()) {
            sortOrder = (existing.map { $0.sortOrder }.max() ?? -1) + 1
        }

        let category = Category(
            name: name,
            icon: icon,
            colorName: color,
            isDefault: false,
            sortOrder: sortOrder,
            isHabitCategory: false
        )
        modelContext.insert(category)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            return .failure("Couldn't save the category: \(error.localizedDescription)")
        }

        let payload = CreateCategorySuccess(id: category.id.uuidString, name: category.name)
        let content = Self.encodeJSON(payload) ?? "{\"id\":\"\(category.id.uuidString)\"}"
        return RepositoryToolResult(
            content: content,
            isError: false,
            reminderID: nil,
            displayTitle: category.name,
            displaySummary: "Category"
        )
    }

    // MARK: Helpers

    private func validCategoriesText() -> String {
        let descriptor = FetchDescriptor<Category>(sortBy: [SortDescriptor(\.sortOrder)])
        guard let categories = try? modelContext.fetch(descriptor), !categories.isEmpty else {
            return "There are no categories yet."
        }
        let list = categories.map { "\($0.name) (\($0.id.uuidString))" }.joined(separator: ", ")
        return "Valid categories: \(list)."
    }

    /// Non-lenient `yyyy-MM-dd` parse pinned to a frozen Gregorian calendar +
    /// fixed timezone, requiring an exact round-trip, normalized to start of day.
    static func parseDate(_ string: String, timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: string) else { return nil }
        guard formatter.string(from: date) == string else { return nil }
        return calendar.startOfDay(for: date)
    }

    /// The day-of-month the first due date of a month-anchored schedule must land
    /// on: the anchor clamped to the due month's length. `monthAnchorDay` only
    /// trusts a stored anchor when the due date sits clamped at a short month's
    /// end, so the executor requires `dueDay == expectedAnchoredDay(...)`.
    static func expectedAnchoredDay(anchorDay: Int, dueDate: Date, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let daysInMonth = calendar.range(of: .day, in: .month, for: dueDate)?.count
            ?? calendar.component(.day, from: dueDate)
        return min(anchorDay, daysInMonth)
    }

    static func dateString(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func cardSummary(
        dueString: String?,
        category: String,
        recurrence: String?,
        priority: ReminderPriority
    ) -> String {
        var parts: [String] = []
        if let recurrence { parts.append(recurrence) }
        else if let dueString { parts.append(dueString) }
        parts.append(category)
        if priority == .urgent { parts.append("Urgent") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Success payloads

private struct CreateReminderSuccess: Encodable {
    let id: String
    let title: String
    let due_date: String?
    let category: String
    let recurrence_description: String?
}

private struct CreateCategorySuccess: Encodable {
    let id: String
    let name: String
}
