//
//  ChatEngineTests.swift
//  GentleNudgeTests
//
//  Unit tests for the conversational-chat engine (increment 2a): deterministic
//  date/anchor validation and the idempotent tool-result replay map.
//

import XCTest
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
            "priority": .string("normal"),
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
            "priority": .string("urgent"),
            "recurrence": .string("monthly"),
            "recurrence_anchor_day": .int(1)
        ])
        let parsed = ChatCoordinator.parseCreateReminder(input)
        XCTAssertEqual(parsed?.priority, "urgent")
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
