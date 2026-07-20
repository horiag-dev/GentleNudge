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
    /// The created reminder's values at creation time. Cards compare the live
    /// reminder against this to decide Undo (still pristine) vs. Delete (changed).
    let snapshot: ReminderSnapshot?

    static func failure(_ message: String) -> RepositoryToolResult {
        RepositoryToolResult(
            content: message,
            isError: true,
            reminderID: nil,
            displayTitle: nil,
            displaySummary: nil,
            snapshot: nil
        )
    }
}

/// An immutable capture of a reminder's mutable fields at creation time. A card's
/// action is **Undo** only while the live reminder still matches this snapshot and
/// carries no post-creation history (see `matchesCreation(_:)`); once anything has
/// changed the action becomes a confirmed **Delete**.
struct ReminderSnapshot: Sendable, Equatable {
    let title: String
    let notes: String
    let dueDate: Date?
    let categoryID: UUID?
    let recurrenceRaw: Int
    let recurrenceAnchorDay: Int?
    let priorityRaw: Int
}

extension ReminderSnapshot {
    /// True while the live reminder still matches its creation snapshot and has
    /// accrued no post-creation state (completion, habit history, Apple-Reminders
    /// sync linkage, or a spawned recurring successor). When false, removal is
    /// destructive and the card offers a confirmed Delete instead of Undo.
    @MainActor
    func matchesCreation(_ r: Reminder) -> Bool {
        !r.isCompleted
            && r.habitCompletionDates.isEmpty
            && !r.hasBeenSynced
            && r.nextOccurrenceID == nil
            && r.title == title
            && r.notes == notes
            && r.dueDate == dueDate
            && r.category?.id == categoryID
            && r.recurrenceRaw == recurrenceRaw
            && r.recurrenceAnchorDay == recurrenceAnchorDay
            && r.priorityRaw == priorityRaw
    }
}

// MARK: - Query / edit result types

/// One row of a `find_reminders` result. Carries both the wire fields (encoded to
/// compact JSON for the model) and card-only display strings. Sendable so it
/// crosses the repository-actor boundary into the transcript.
struct FindRow: Sendable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let dueDate: String?      // wire: YYYY-MM-DD (nil if undated)
    let dueDisplay: String?   // card: "Fri, Jul 24" / "Today" / nil
    let category: String?
    let recurrence: String?   // detailed recurrence, or nil
    let isCompleted: Bool
    let isOverdue: Bool
}

/// Result of `find_reminders`: the wire JSON plus the rows (≤20) for the card.
struct FindRemindersResult: Sendable {
    let content: String
    let isError: Bool
    let query: String?
    let rows: [FindRow]
    let totalMatches: Int
}

/// A single field change applied by `update_reminder`, phrased for the diff card
/// ("Due → Fri, Jul 24", "Recurrence → Monthly").
struct ReminderFieldChange: Sendable, Identifiable, Equatable {
    let id = UUID()
    let label: String
    let value: String
}

/// Result of `update_reminder`.
struct UpdateReminderResult: Sendable {
    let content: String
    let isError: Bool
    let reminderID: UUID?
    let title: String?
    let changes: [ReminderFieldChange]
}

/// Result of `complete_reminder` / `uncomplete_reminder`.
struct CompletionResult: Sendable {
    let content: String
    let isError: Bool
    let reminderID: UUID?
    let title: String?
    /// The reminder's completed flag after the action (false for habits, which
    /// track per-day history instead of a permanent completion).
    let isCompleted: Bool
    /// A short human detail for the card, e.g. "Next on Aug 1" or "Marked done today".
    let detail: String?
    /// True for the uncomplete action (drives the card's undo styling).
    let isUndo: Bool
}

/// Result of the confirmed `delete_reminder`.
struct DeleteResult: Sendable {
    let content: String
    let isError: Bool
    let title: String?
    let didDelete: Bool
}

extension FindRemindersResult {
    static func findFailure(_ message: String, query: String?) -> FindRemindersResult {
        FindRemindersResult(content: message, isError: true, query: query, rows: [], totalMatches: 0)
    }
}

extension UpdateReminderResult {
    static func updateFailure(_ message: String) -> UpdateReminderResult {
        UpdateReminderResult(content: message, isError: true, reminderID: nil, title: nil, changes: [])
    }
}

extension CompletionResult {
    static func completionFailure(_ message: String, isUndo: Bool) -> CompletionResult {
        CompletionResult(content: message, isError: true, reminderID: nil, title: nil, isCompleted: false, detail: nil, isUndo: isUndo)
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

        // Chat never sets priority (the priority UI was removed): always create at
        // the model's default `.normal`.
        let reminder = Reminder(
            title: input.title,
            notes: input.notes ?? "",
            dueDate: dueDate,
            priority: .normal,
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
            recurrence: recurrenceDescription
        )
        let snapshot = ReminderSnapshot(
            title: reminder.title,
            notes: reminder.notes,
            dueDate: reminder.dueDate,
            categoryID: category.id,
            recurrenceRaw: reminder.recurrenceRaw,
            recurrenceAnchorDay: reminder.recurrenceAnchorDay,
            priorityRaw: reminder.priorityRaw
        )
        return RepositoryToolResult(
            content: content,
            isError: false,
            reminderID: reminder.id,
            displayTitle: reminder.title,
            displaySummary: summary,
            snapshot: snapshot
        )
    }

    // MARK: find_reminders

    /// In-memory filter over all reminders (personal scale). Returns ≤20 rows plus
    /// the full `total_matches`. Date bounds are inclusive: `due_to` is compared
    /// against the START of the next day, so a reminder carrying a time-of-day
    /// (e.g. a snooze that set 9 AM) still matches its due day.
    func findReminders(_ input: FindRemindersInput, timeZone: TimeZone) -> FindRemindersResult {
        let status = input.status.lowercased()
        guard ChatTools.statusValues.contains(status) else {
            return .findFailure("Unknown status '\(input.status)'. Use active, completed, or any.", query: input.query)
        }

        var categoryFilterID: UUID?
        if let raw = input.categoryID, !raw.isEmpty {
            guard let uuid = UUID(uuidString: raw) else {
                return .findFailure("Invalid category_id '\(raw)'. \(validCategoriesText())", query: input.query)
            }
            var descriptor = FetchDescriptor<Category>(predicate: #Predicate { $0.id == uuid })
            descriptor.fetchLimit = 1
            guard (try? modelContext.fetch(descriptor).first) != nil else {
                return .findFailure("Unknown category \(raw). \(validCategoriesText())", query: input.query)
            }
            categoryFilterID = uuid
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var fromBound: Date?
        if let raw = input.dueFrom, !raw.isEmpty {
            guard let d = Self.parseDate(raw, timeZone: timeZone) else {
                return .findFailure("Invalid due_from '\(raw)'. Use YYYY-MM-DD.", query: input.query)
            }
            fromBound = d
        }
        var toBoundExclusive: Date?
        if let raw = input.dueTo, !raw.isEmpty {
            guard let d = Self.parseDate(raw, timeZone: timeZone) else {
                return .findFailure("Invalid due_to '\(raw)'. Use YYYY-MM-DD.", query: input.query)
            }
            toBoundExclusive = calendar.date(byAdding: .day, value: 1, to: d) ?? d
        }
        if let f = fromBound, let t = toBoundExclusive, t <= f {
            return .findFailure("due_to must be on or after due_from.", query: input.query)
        }

        let hasDateBound = fromBound != nil || toBoundExclusive != nil
        let needle = input.query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let all = (try? modelContext.fetch(FetchDescriptor<Reminder>())) ?? []
        let matches = all.filter { r in
            switch status {
            case "active": if r.isCompleted { return false }
            case "completed": if !r.isCompleted { return false }
            default: break
            }
            if input.overdueOnly, !r.isOverdue { return false }
            if let categoryFilterID, r.category?.id != categoryFilterID { return false }
            if let needle, !needle.isEmpty {
                let hay = (r.title + "\n" + r.notes).lowercased()
                if !hay.contains(needle) { return false }
            }
            if hasDateBound {
                guard let due = r.dueDate else { return false }
                if let fromBound, due < fromBound { return false }
                if let toBoundExclusive, due >= toBoundExclusive { return false }
            }
            return true
        }

        let total = matches.count
        // Dated ascending (soonest first), undated last, then title.
        let sorted = matches.sorted { a, b in
            switch (a.dueDate, b.dueDate) {
            case let (da?, db?): if da != db { return da < db }
            case (nil, .some): return false
            case (.some, nil): return true
            default: break
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
        let rows = sorted.prefix(20).map { Self.makeFindRow($0, calendar: calendar, timeZone: timeZone) }

        let wireRows = rows.map {
            FindRowWire(
                id: $0.id.uuidString, title: $0.title, due_date: $0.dueDate,
                category: $0.category, recurrence: $0.recurrence,
                is_completed: $0.isCompleted, is_overdue: $0.isOverdue
            )
        }
        let payload = FindRemindersSuccess(total_matches: total, returned: rows.count, reminders: wireRows)
        let content = Self.encodeJSON(payload) ?? "{\"total_matches\":\(total)}"
        return FindRemindersResult(content: content, isError: false, query: input.query, rows: Array(rows), totalMatches: total)
    }

    // MARK: update_reminder

    /// Applies field changes to one reminder. `null` fields are untouched;
    /// `clear_due_date` removes the date (and recurrence + anchor). Any date or
    /// recurrence change resets `recurrenceAnchorDay` the way the model does when a
    /// due date is edited, unless an explicit (validated) anchor is supplied.
    func updateReminder(_ input: UpdateReminderInput, timeZone: TimeZone) -> UpdateReminderResult {
        guard let uuid = UUID(uuidString: input.id) else {
            return .updateFailure("Invalid reminder id '\(input.id)'. Use an id from find_reminders.")
        }
        guard let reminder = fetchReminder(id: uuid) else {
            return .updateFailure("No reminder with id \(input.id) exists. It may have been deleted; run find_reminders again.")
        }
        if input.clearDueDate, let d = input.dueDate, !d.isEmpty {
            return .updateFailure("Can't both set and clear the due date. Provide either due_date or clear_due_date, not both.")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var changes: [ReminderFieldChange] = []

        if let title = input.title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .updateFailure("A reminder title can't be empty.") }
            if trimmed != reminder.title {
                reminder.title = trimmed
                changes.append(ReminderFieldChange(label: "Title", value: trimmed))
            }
        }

        if let notes = input.notes, notes != reminder.notes {
            reminder.notes = notes
            changes.append(ReminderFieldChange(label: "Notes", value: notes.isEmpty ? "Cleared" : notes))
        }

        if let raw = input.categoryID, !raw.isEmpty {
            guard let catUUID = UUID(uuidString: raw) else {
                return .updateFailure("Invalid category_id '\(raw)'. \(validCategoriesText())")
            }
            var descriptor = FetchDescriptor<Category>(predicate: #Predicate { $0.id == catUUID })
            descriptor.fetchLimit = 1
            guard let category = try? modelContext.fetch(descriptor).first else {
                return .updateFailure("Unknown category \(raw). \(validCategoriesText())")
            }
            if reminder.category?.id != category.id {
                reminder.category = category
                changes.append(ReminderFieldChange(label: "Category", value: category.name))
            }
        }

        // Date + recurrence + anchor are interdependent — resolve together.
        if input.clearDueDate {
            if reminder.dueDate != nil {
                reminder.dueDate = nil
                changes.append(ReminderFieldChange(label: "Due", value: "Cleared"))
            }
            if reminder.recurrence != .none {
                reminder.recurrence = .none
                changes.append(ReminderFieldChange(label: "Recurrence", value: "Removed"))
            }
            reminder.recurrenceAnchorDay = nil
        } else {
            var newDueDate: Date? = reminder.dueDate
            var dueChanged = false
            if let raw = input.dueDate, !raw.isEmpty {
                guard let parsed = Self.parseDate(raw, timeZone: timeZone) else {
                    return .updateFailure("Invalid due_date '\(raw)'. Use a real YYYY-MM-DD date.")
                }
                if parsed != reminder.dueDate { newDueDate = parsed; dueChanged = true }
            }

            var newRecurrence = reminder.recurrence
            var recurrenceChanged = false
            if let raw = input.recurrence {
                guard let rec = RecurrenceType.fromToolValue(raw) else {
                    return .updateFailure("Unknown recurrence '\(raw)'. Supported: \(ChatTools.recurrenceValues.joined(separator: ", ")).")
                }
                if rec != reminder.recurrence { newRecurrence = rec; recurrenceChanged = true }
            }

            if newRecurrence != .none, newDueDate == nil {
                return .updateFailure("A \(newRecurrence.label.lowercased()) reminder needs a due date. Set due_date or use a non-recurring cadence.")
            }

            // Anchor: an explicit value is validated; otherwise a date/recurrence
            // change resets it (defaults to the due date's own day-of-month).
            if newRecurrence.isMonthBased {
                if let candidate = input.recurrenceAnchorDay {
                    guard (1...31).contains(candidate) else {
                        return .updateFailure("recurrence_anchor_day must be between 1 and 31.")
                    }
                    if let due = newDueDate {
                        let dueDay = calendar.component(.day, from: due)
                        let expected = Self.expectedAnchoredDay(anchorDay: candidate, dueDate: due, timeZone: timeZone)
                        if dueDay != expected {
                            return .updateFailure("For a \(newRecurrence.label.lowercased()) schedule anchored to day \(candidate), the due date must fall on day \(expected) of its month, but it is day \(dueDay). Adjust due_date or recurrence_anchor_day.")
                        }
                    }
                    reminder.recurrenceAnchorDay = candidate
                } else if dueChanged || recurrenceChanged {
                    reminder.recurrenceAnchorDay = nil
                }
            } else {
                reminder.recurrenceAnchorDay = nil
            }

            if dueChanged {
                reminder.dueDate = newDueDate
                let display = newDueDate.map { Self.displayDate($0, calendar: calendar, timeZone: timeZone) } ?? "Cleared"
                changes.append(ReminderFieldChange(label: "Due", value: display))
            }
            if recurrenceChanged {
                reminder.recurrence = newRecurrence
                let value = newRecurrence == .none ? "None" : (reminder.detailedRecurrence ?? newRecurrence.label)
                changes.append(ReminderFieldChange(label: "Recurrence", value: value))
            }
        }

        guard !changes.isEmpty else {
            let payload = UpdateNoChange(id: reminder.id.uuidString, updated: false)
            let content = Self.encodeJSON(payload) ?? "{\"updated\":false}"
            return UpdateReminderResult(content: content, isError: false, reminderID: reminder.id, title: reminder.title, changes: [])
        }

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            return .updateFailure("Couldn't save the changes: \(error.localizedDescription)")
        }

        let dueString = reminder.dueDate.map { Self.dateString($0, timeZone: timeZone) }
        let recDesc = reminder.isRecurring ? (reminder.detailedRecurrence ?? reminder.recurrence.label) : nil
        let payload = UpdateReminderSuccess(
            id: reminder.id.uuidString, title: reminder.title, due_date: dueString,
            category: reminder.category?.name,
            recurrence: reminder.recurrence == .none ? "none" : recDesc, updated: true
        )
        let content = Self.encodeJSON(payload) ?? "{\"updated\":true}"
        return UpdateReminderResult(content: content, isError: false, reminderID: reminder.id, title: reminder.title, changes: changes)
    }

    // MARK: complete_reminder / uncomplete_reminder

    /// Completes a reminder through `complete(in:)` so recurring items spawn a
    /// successor and habits route to `markHabitDoneToday()` — never `markCompleted()`.
    func completeReminder(id rawID: String, timeZone: TimeZone) -> CompletionResult {
        guard let uuid = UUID(uuidString: rawID) else {
            return .completionFailure("Invalid reminder id '\(rawID)'. Use an id from find_reminders.", isUndo: false)
        }
        guard let reminder = fetchReminder(id: uuid) else {
            return .completionFailure("No reminder with id \(rawID) exists. Run find_reminders again.", isUndo: false)
        }
        let wasHabit = reminder.isHabit
        if !wasHabit, reminder.isCompleted {
            let payload = CompletionSuccess(id: reminder.id.uuidString, title: reminder.title, completed: true, note: "already completed")
            let content = Self.encodeJSON(payload) ?? "{\"completed\":true}"
            return CompletionResult(content: content, isError: false, reminderID: reminder.id, title: reminder.title, isCompleted: true, detail: "Already done", isUndo: false)
        }

        reminder.complete(in: modelContext)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            return .completionFailure("Couldn't save the completion: \(error.localizedDescription)", isUndo: false)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var detail: String?
        if wasHabit {
            detail = "Marked done today"
        } else if let spawnedID = reminder.nextOccurrenceID,
                  let next = fetchReminder(id: spawnedID), let due = next.dueDate {
            detail = "Next on " + Self.displayDate(due, calendar: calendar, timeZone: timeZone)
        }
        let payload = CompletionSuccess(id: reminder.id.uuidString, title: reminder.title, completed: !wasHabit, note: detail)
        let content = Self.encodeJSON(payload) ?? "{\"completed\":true}"
        return CompletionResult(content: content, isError: false, reminderID: reminder.id, title: reminder.title, isCompleted: reminder.isCompleted, detail: detail, isUndo: false)
    }

    /// Undoes a completion via `uncomplete(in:)` (which removes a spawned recurring
    /// successor). Habits use the symmetric `clearHabitCompletion()`.
    func uncompleteReminder(id rawID: String, timeZone: TimeZone) -> CompletionResult {
        guard let uuid = UUID(uuidString: rawID) else {
            return .completionFailure("Invalid reminder id '\(rawID)'. Use an id from find_reminders.", isUndo: true)
        }
        guard let reminder = fetchReminder(id: uuid) else {
            return .completionFailure("No reminder with id \(rawID) exists. Run find_reminders again.", isUndo: true)
        }
        let wasHabit = reminder.isHabit
        if wasHabit {
            reminder.clearHabitCompletion()
        } else {
            guard reminder.isCompleted else {
                let payload = CompletionSuccess(id: reminder.id.uuidString, title: reminder.title, completed: false, note: "was not completed")
                let content = Self.encodeJSON(payload) ?? "{\"completed\":false}"
                return CompletionResult(content: content, isError: false, reminderID: reminder.id, title: reminder.title, isCompleted: false, detail: "Already not done", isUndo: true)
            }
            reminder.uncomplete(in: modelContext)
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            return .completionFailure("Couldn't save the change: \(error.localizedDescription)", isUndo: true)
        }

        let detail = wasHabit ? "Cleared today" : "Marked not done"
        let payload = CompletionSuccess(id: reminder.id.uuidString, title: reminder.title, completed: false, note: detail)
        let content = Self.encodeJSON(payload) ?? "{\"completed\":false}"
        return CompletionResult(content: content, isError: false, reminderID: reminder.id, title: reminder.title, isCompleted: reminder.isCompleted, detail: detail, isUndo: true)
    }

    // MARK: Undo / Delete

    /// Removes a chat-created reminder through this isolated context (card
    /// Undo/Delete path). If the reminder had been completed and spawned a
    /// recurring successor, undo that first (`uncomplete(in:)`) so we never orphan
    /// a pristine future occurrence. A no-op if the reminder has already vanished.
    @discardableResult
    func deleteReminder(id: UUID) -> Bool {
        removeReminder(id: id).didDelete
    }

    /// The title of a reminder, for the delete confirmation gate. Nil if gone.
    func reminderTitle(id rawID: String) -> String? {
        guard let uuid = UUID(uuidString: rawID) else { return nil }
        return fetchReminder(id: uuid)?.title
    }

    /// Confirmed delete for the `delete_reminder` tool, run only after the user
    /// approves the gate. Returns a compact result the model acknowledges.
    func confirmDelete(id rawID: String) -> DeleteResult {
        guard let uuid = UUID(uuidString: rawID) else {
            return DeleteResult(content: "Invalid reminder id '\(rawID)'.", isError: true, title: nil, didDelete: false)
        }
        let outcome = removeReminder(id: uuid)
        guard outcome.didDelete, let title = outcome.title else {
            return DeleteResult(
                content: "No reminder with id \(rawID) exists (it may have already been removed).",
                isError: true, title: outcome.title, didDelete: false
            )
        }
        let payload = DeleteSuccess(id: rawID, title: title, deleted: true)
        let content = Self.encodeJSON(payload) ?? "{\"deleted\":true}"
        return DeleteResult(content: content, isError: false, title: title, didDelete: true)
    }

    private func removeReminder(id: UUID) -> (didDelete: Bool, title: String?) {
        guard let reminder = fetchReminder(id: id) else { return (false, nil) }
        let title = reminder.title
        if reminder.nextOccurrenceID != nil {
            reminder.uncomplete(in: modelContext)
        }
        modelContext.delete(reminder)
        do {
            try modelContext.save()
            return (true, title)
        } catch {
            modelContext.rollback()
            return (false, title)
        }
    }

    private func fetchReminder(id: UUID) -> Reminder? {
        var descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
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
            displaySummary: "Category",
            snapshot: nil
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

    /// Friendly card date: "Today"/"Tomorrow"/"Yesterday" near now, else "Fri, Jul 24".
    static func displayDate(_ date: Date, calendar: Calendar, timeZone: TimeZone) -> String {
        let today = calendar.startOfDay(for: Date())
        let day = calendar.startOfDay(for: date)
        if let diff = calendar.dateComponents([.day], from: today, to: day).day {
            switch diff {
            case 0: return "Today"
            case 1: return "Tomorrow"
            case -1: return "Yesterday"
            default: break
            }
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter.string(from: date)
    }

    /// Builds one `find_reminders` row (wire + card fields) from a live reminder.
    static func makeFindRow(_ r: Reminder, calendar: Calendar, timeZone: TimeZone) -> FindRow {
        FindRow(
            id: r.id,
            title: r.title,
            dueDate: r.dueDate.map { dateString($0, timeZone: timeZone) },
            dueDisplay: r.dueDate.map { displayDate($0, calendar: calendar, timeZone: timeZone) },
            category: r.category?.name,
            recurrence: r.isRecurring ? (r.detailedRecurrence ?? r.recurrence.label) : nil,
            isCompleted: r.isCompleted,
            isOverdue: r.isOverdue
        )
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
        recurrence: String?
    ) -> String {
        var parts: [String] = []
        if let recurrence { parts.append(recurrence) }
        else if let dueString { parts.append(dueString) }
        parts.append(category)
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

private struct FindRowWire: Encodable {
    let id: String
    let title: String
    let due_date: String?
    let category: String?
    let recurrence: String?
    let is_completed: Bool
    let is_overdue: Bool
}

private struct FindRemindersSuccess: Encodable {
    let total_matches: Int
    let returned: Int
    let reminders: [FindRowWire]
}

private struct UpdateReminderSuccess: Encodable {
    let id: String
    let title: String
    let due_date: String?
    let category: String?
    let recurrence: String?
    let updated: Bool
}

private struct UpdateNoChange: Encodable {
    let id: String
    let updated: Bool
}

private struct CompletionSuccess: Encodable {
    let id: String
    let title: String
    let completed: Bool
    let note: String?
}

private struct DeleteSuccess: Encodable {
    let id: String
    let title: String
    let deleted: Bool
}
