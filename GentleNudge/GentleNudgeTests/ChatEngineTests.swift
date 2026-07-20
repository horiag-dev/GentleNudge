//
//  ChatEngineTests.swift
//  GentleNudgeTests
//
//  Unit tests for the conversational-chat engine (increment 2a): deterministic
//  date/anchor validation and the idempotent tool-result replay map.
//

import XCTest
import SwiftData
@testable import GentleNudge_iOS

final class ChatEngineDateParsingTests: XCTestCase {
    private let tz = TimeZone(identifier: "America/New_York")!

    func test_parseDate_validDate_returnsStartOfDay() {
        let date = ReminderRepository.parseDate("2026-07-21", timeZone: tz)
        XCTAssertNotNil(date)
        // Round-trips back to the same string in the same timezone.
        XCTAssertEqual(ReminderRepository.dateString(date!, timeZone: tz), "2026-07-21")
    }

    func test_parseDate_nonRealDate_returnsNil() {
        // 2026 is not a leap year, so Feb 29 is invalid.
        XCTAssertNil(ReminderRepository.parseDate("2026-02-29", timeZone: tz))
        XCTAssertNil(ReminderRepository.parseDate("2026-13-01", timeZone: tz))
        XCTAssertNil(ReminderRepository.parseDate("2026-04-31", timeZone: tz))
    }

    func test_parseDate_wrongFormat_returnsNil() {
        // Round-trip guard rejects loosely-formatted input.
        XCTAssertNil(ReminderRepository.parseDate("2026-2-5", timeZone: tz))
        XCTAssertNil(ReminderRepository.parseDate("07/21/2026", timeZone: tz))
        XCTAssertNil(ReminderRepository.parseDate("tomorrow", timeZone: tz))
    }
}

final class ChatEngineAnchorTests: XCTestCase {
    private let tz = TimeZone(identifier: "America/New_York")!

    func test_anchor31_inThirtyDayMonth_clampsToThirty() {
        let april30 = ReminderRepository.parseDate("2026-04-30", timeZone: tz)!
        XCTAssertEqual(ReminderRepository.expectedAnchoredDay(anchorDay: 31, dueDate: april30, timeZone: tz), 30)
    }

    func test_anchor31_inFebruaryNonLeap_clampsTo28() {
        let feb28 = ReminderRepository.parseDate("2026-02-28", timeZone: tz)!
        XCTAssertEqual(ReminderRepository.expectedAnchoredDay(anchorDay: 31, dueDate: feb28, timeZone: tz), 28)
    }

    func test_anchor15_matchesFifteenthOfLongMonth() {
        let april15 = ReminderRepository.parseDate("2026-04-15", timeZone: tz)!
        // April 15 + anchor 31 is a mismatch: expected day is 30, not 15.
        XCTAssertEqual(ReminderRepository.expectedAnchoredDay(anchorDay: 31, dueDate: april15, timeZone: tz), 30)
        // April 15 + anchor 15 is consistent.
        XCTAssertEqual(ReminderRepository.expectedAnchoredDay(anchorDay: 15, dueDate: april15, timeZone: tz), 15)
    }
}

final class ToolResultReplayMapTests: XCTestCase {
    func test_recordAndRetrieve() {
        var map = ToolResultReplayMap<Int>()
        XCTAssertNil(map.value(for: "toolu_a"))
        map.record(42, for: "toolu_a")
        XCTAssertEqual(map.value(for: "toolu_a"), 42)
    }

    func test_recordIsIdempotent_firstResultWins() {
        var map = ToolResultReplayMap<Int>()
        map.record(1, for: "toolu_a")
        map.record(2, for: "toolu_a") // ignored — id already recorded
        XCTAssertEqual(map.value(for: "toolu_a"), 1)
    }

    func test_replayNeverReExecutes() {
        // Simulates the loop's check-then-execute pattern: a replayed id must
        // reuse the stored result rather than run the executor again.
        var executions = 0
        func execute() -> String {
            executions += 1
            return "created"
        }

        var map = ToolResultReplayMap<String>()
        let id = "toolu_create"

        // First pass: not stored → execute + record.
        if map.value(for: id) == nil {
            map.record(execute(), for: id)
        }
        // Second pass (retry / replay): stored → reuse, no execution.
        if map.value(for: id) == nil {
            map.record(execute(), for: id)
        }

        XCTAssertEqual(executions, 1, "A replayed tool_use id must not re-execute (no double-create).")
    }
}

final class ChatToolParsingTests: XCTestCase {
    func test_parseCreateReminder_nullableFields() {
        let input = JSONValue.object([
            "title": .string("Call the dentist"),
            "notes": .null,
            "due_date": .string("2026-07-21"),
            "category_id": .string("11111111-1111-1111-1111-111111111111"),
            "recurrence": .string("none"),
            "recurrence_anchor_day": .null
        ])
        let parsed = ChatCoordinator.parseCreateReminder(input)
        XCTAssertEqual(parsed?.title, "Call the dentist")
        XCTAssertNil(parsed?.notes)
        XCTAssertEqual(parsed?.dueDate, "2026-07-21")
        XCTAssertEqual(parsed?.categoryID, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(parsed?.recurrence, "none")
        XCTAssertNil(parsed?.recurrenceAnchorDay)
    }

    func test_parseCreateReminder_monthlyWithAnchor() {
        let input = JSONValue.object([
            "title": .string("Pay rent"),
            "notes": .null,
            "due_date": .string("2026-08-01"),
            "category_id": .string("22222222-2222-2222-2222-222222222222"),
            "recurrence": .string("monthly"),
            "recurrence_anchor_day": .int(1)
        ])
        let parsed = ChatCoordinator.parseCreateReminder(input)
        XCTAssertEqual(parsed?.recurrence, "monthly")
        XCTAssertEqual(parsed?.recurrenceAnchorDay, 1)
    }

    func test_parseCreateReminder_missingTitle_returnsNil() {
        let input = JSONValue.object([
            "category_id": .string("33333333-3333-3333-3333-333333333333")
        ])
        XCTAssertNil(ChatCoordinator.parseCreateReminder(input))
    }

    func test_recurrenceMapping() {
        XCTAssertEqual(RecurrenceType.fromToolValue("none"), RecurrenceType.none)
        XCTAssertEqual(RecurrenceType.fromToolValue("monthly"), .monthly)
        XCTAssertEqual(RecurrenceType.fromToolValue("semiannually"), .semiannually)
        XCTAssertNil(RecurrenceType.fromToolValue("every_10_days"))
        XCTAssertTrue(RecurrenceType.monthly.isMonthBased)
        XCTAssertFalse(RecurrenceType.weekly.isMonthBased)
    }
}

// MARK: - Phase 3 executor tests (find / update / complete)

/// Exercises the new repository executors against an in-memory store. Seed and
/// assertion reads use fresh `ModelContext`s over the shared container so they see
/// the repository actor's committed writes (never a stale cached instance).
final class ChatEngineExecutorTests: XCTestCase {
    private let tz = TimeZone(identifier: "America/New_York")!

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Reminder.self, Category.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func date(_ string: String, hour: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let base = ReminderRepository.parseDate(string, timeZone: tz)!
        return cal.date(byAdding: .hour, value: hour, to: base)!
    }

    @discardableResult
    private func seedCategory(_ container: ModelContainer, name: String, habit: Bool = false) -> UUID {
        let ctx = ModelContext(container)
        let cat = GentleNudge_iOS.Category(name: name, icon: "folder.fill", colorName: "gray", isHabitCategory: habit)
        ctx.insert(cat)
        try? ctx.save()
        return cat.id
    }

    @discardableResult
    private func seedReminder(
        _ container: ModelContainer,
        title: String,
        due: Date?,
        categoryID: UUID,
        recurrence: RecurrenceType = .none,
        anchor: Int? = nil
    ) -> UUID {
        let ctx = ModelContext(container)
        var descriptor = FetchDescriptor<GentleNudge_iOS.Category>(
            predicate: #Predicate<GentleNudge_iOS.Category> { $0.id == categoryID }
        )
        descriptor.fetchLimit = 1
        let category = try? ctx.fetch(descriptor).first
        let reminder = Reminder(title: title, dueDate: due, category: category, recurrence: recurrence)
        reminder.recurrenceAnchorDay = anchor
        ctx.insert(reminder)
        try? ctx.save()
        return reminder.id
    }

    private func freshReminder(_ container: ModelContainer, id: UUID) -> Reminder? {
        let ctx = ModelContext(container)
        var descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? ctx.fetch(descriptor).first
    }

    private func freshReminders(_ container: ModelContainer) -> [Reminder] {
        let ctx = ModelContext(container)
        return (try? ctx.fetch(FetchDescriptor<Reminder>())) ?? []
    }

    private func markCompleted(_ container: ModelContainer, id: UUID) {
        let ctx = ModelContext(container)
        var descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let reminder = try? ctx.fetch(descriptor).first {
            reminder.isCompleted = true
            reminder.completedAt = Date()
            try? ctx.save()
        }
    }

    // MARK: find_reminders

    func test_findReminders_dueToIsInclusiveOfTimedReminders() async throws {
        let container = try makeContainer()
        let catID = seedCategory(container, name: "Finance")
        // A reminder carrying a time-of-day on the boundary day (snooze sets 9 AM).
        seedReminder(container, title: "Pay rent", due: date("2026-07-24", hour: 9), categoryID: catID)
        seedReminder(container, title: "Next day", due: date("2026-07-25"), categoryID: catID)

        let repo = ReminderRepository(modelContainer: container)
        let input = FindRemindersInput(
            query: nil, categoryID: nil, status: "any",
            dueFrom: nil, dueTo: "2026-07-24", overdueOnly: false
        )
        let result = await repo.findReminders(input, timeZone: tz)

        XCTAssertFalse(result.isError)
        // The 9 AM reminder on the 24th is included (bound is the START of the 25th);
        // the 25th is excluded. A naive start-of-24 truncation would drop it.
        XCTAssertEqual(result.totalMatches, 1)
        XCTAssertEqual(result.rows.first?.title, "Pay rent")
    }

    func test_findReminders_filtersByStatusAndQuery() async throws {
        let container = try makeContainer()
        let catID = seedCategory(container, name: "House")
        seedReminder(container, title: "Water plants", due: date("2026-07-20"), categoryID: catID)
        let doneID = seedReminder(container, title: "Take out trash", due: date("2026-07-19"), categoryID: catID)
        markCompleted(container, id: doneID)

        let repo = ReminderRepository(modelContainer: container)
        let active = await repo.findReminders(
            FindRemindersInput(query: nil, categoryID: nil, status: "active", dueFrom: nil, dueTo: nil, overdueOnly: false),
            timeZone: tz
        )
        XCTAssertEqual(active.totalMatches, 1)
        XCTAssertEqual(active.rows.first?.title, "Water plants")

        let byQuery = await repo.findReminders(
            FindRemindersInput(query: "trash", categoryID: nil, status: "any", dueFrom: nil, dueTo: nil, overdueOnly: false),
            timeZone: tz
        )
        XCTAssertEqual(byQuery.totalMatches, 1)
        XCTAssertEqual(byQuery.rows.first?.title, "Take out trash")
    }

    // MARK: update_reminder

    func test_updateReminder_clearDueDateAlsoClearsRecurrence() async throws {
        let container = try makeContainer()
        let catID = seedCategory(container, name: "Finance")
        let id = seedReminder(container, title: "Pay rent", due: date("2026-08-01"), categoryID: catID, recurrence: .monthly, anchor: 1)

        let repo = ReminderRepository(modelContainer: container)
        let input = UpdateReminderInput(
            id: id.uuidString, title: nil, notes: nil, dueDate: nil,
            clearDueDate: true, categoryID: nil, recurrence: nil, recurrenceAnchorDay: nil
        )
        let result = await repo.updateReminder(input, timeZone: tz)
        XCTAssertFalse(result.isError)

        let r = freshReminder(container, id: id)
        XCTAssertNil(r?.dueDate)
        XCTAssertEqual(r?.recurrence, RecurrenceType.none)
        XCTAssertNil(r?.recurrenceAnchorDay)
    }

    func test_updateReminder_rejectsSetAndClearTogether() async throws {
        let container = try makeContainer()
        let catID = seedCategory(container, name: "Finance")
        let id = seedReminder(container, title: "x", due: date("2026-08-01"), categoryID: catID)

        let repo = ReminderRepository(modelContainer: container)
        let input = UpdateReminderInput(
            id: id.uuidString, title: nil, notes: nil, dueDate: "2026-09-01",
            clearDueDate: true, categoryID: nil, recurrence: nil, recurrenceAnchorDay: nil
        )
        let result = await repo.updateReminder(input, timeZone: tz)
        XCTAssertTrue(result.isError)
        // Untouched.
        XCTAssertEqual(freshReminder(container, id: id)?.dueDate, date("2026-08-01"))
    }

    func test_updateReminder_changingDueDateResetsAnchor() async throws {
        let container = try makeContainer()
        let catID = seedCategory(container, name: "Finance")
        // Monthly anchored to 31 with the due date clamped to Feb 28.
        let id = seedReminder(container, title: "Pay", due: date("2026-02-28"), categoryID: catID, recurrence: .monthly, anchor: 31)

        let repo = ReminderRepository(modelContainer: container)
        let input = UpdateReminderInput(
            id: id.uuidString, title: nil, notes: nil, dueDate: "2026-03-15",
            clearDueDate: false, categoryID: nil, recurrence: nil, recurrenceAnchorDay: nil
        )
        let result = await repo.updateReminder(input, timeZone: tz)
        XCTAssertFalse(result.isError)

        let r = freshReminder(container, id: id)
        // The anchor resets (defaults to the new due date's own day-of-month).
        XCTAssertNil(r?.recurrenceAnchorDay)
        XCTAssertEqual(r?.recurrence, RecurrenceType.monthly)
        XCTAssertEqual(r?.dueDate, date("2026-03-15"))
    }

    func test_updateReminder_noChangesIsCalmSuccess() async throws {
        let container = try makeContainer()
        let catID = seedCategory(container, name: "Finance")
        let id = seedReminder(container, title: "x", due: date("2026-08-01"), categoryID: catID)

        let repo = ReminderRepository(modelContainer: container)
        let input = UpdateReminderInput(
            id: id.uuidString, title: nil, notes: nil, dueDate: nil,
            clearDueDate: false, categoryID: nil, recurrence: nil, recurrenceAnchorDay: nil
        )
        let result = await repo.updateReminder(input, timeZone: tz)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.changes.isEmpty)
    }

    // MARK: complete_reminder / uncomplete_reminder

    func test_completeReminder_recurringSpawnsSuccessor() async throws {
        let container = try makeContainer()
        let catID = seedCategory(container, name: "House")
        let id = seedReminder(container, title: "Water plants", due: date("2026-07-20"), categoryID: catID, recurrence: .weekly)

        let repo = ReminderRepository(modelContainer: container)
        let result = await repo.completeReminder(id: id.uuidString, timeZone: tz)
        XCTAssertFalse(result.isError)

        let all = freshReminders(container)
        // complete(in:) spawns the next occurrence — markCompleted() would not.
        XCTAssertEqual(all.count, 2)
        let original = all.first { $0.id == id }
        XCTAssertEqual(original?.isCompleted, true)
        XCTAssertNotNil(original?.nextOccurrenceID)
        XCTAssertEqual(all.first { $0.id != id }?.isCompleted, false)
    }

    func test_completeReminder_habitMarksDoneTodayNotCompleted() async throws {
        let container = try makeContainer()
        let habitID = seedCategory(container, name: "Habits", habit: true)
        let id = seedReminder(container, title: "Meditate", due: nil, categoryID: habitID)

        let repo = ReminderRepository(modelContainer: container)
        let result = await repo.completeReminder(id: id.uuidString, timeZone: tz)
        XCTAssertFalse(result.isError)

        let r = freshReminder(container, id: id)
        // Habits route to markHabitDoneToday() — per-day history, never permanent completion.
        XCTAssertEqual(r?.isCompleted, false)
        XCTAssertEqual(r?.habitCompletionDates.isEmpty, false)
    }

    func test_uncompleteReminder_removesSpawnedSuccessor() async throws {
        let container = try makeContainer()
        let catID = seedCategory(container, name: "House")
        let id = seedReminder(container, title: "Water plants", due: date("2026-07-20"), categoryID: catID, recurrence: .weekly)

        let repo = ReminderRepository(modelContainer: container)
        _ = await repo.completeReminder(id: id.uuidString, timeZone: tz)
        XCTAssertEqual(freshReminders(container).count, 2)

        let undo = await repo.uncompleteReminder(id: id.uuidString, timeZone: tz)
        XCTAssertFalse(undo.isError)
        // uncomplete(in:) removes the pristine spawned occurrence.
        let all = freshReminders(container)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.isCompleted, false)
    }

    // MARK: delete_reminder (confirmed path)

    func test_confirmDelete_removesReminder() async throws {
        let container = try makeContainer()
        let catID = seedCategory(container, name: "House")
        let id = seedReminder(container, title: "Old task", due: nil, categoryID: catID)

        let repo = ReminderRepository(modelContainer: container)
        let title = await repo.reminderTitle(id: id.uuidString)
        XCTAssertEqual(title, "Old task")

        let result = await repo.confirmDelete(id: id.uuidString)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.didDelete)
        XCTAssertTrue(freshReminders(container).isEmpty)
    }
}
