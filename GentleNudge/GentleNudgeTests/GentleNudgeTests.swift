//
//  GentleNudgeTests.swift
//  GentleNudgeTests
//
//  Created by Horia Galatanu on 12/27/25.
//

import XCTest
@testable import GentleNudge_iOS

final class ReminderTests: XCTestCase {

    // MARK: - isOverdue Tests

    func test_isOverdue_dueYesterday_returnsTrue() {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!

        let reminder = Reminder(title: "Test", dueDate: yesterday)

        XCTAssertTrue(reminder.isOverdue)
    }

    func test_isOverdue_dueToday_returnsFalse() {
        let today = Calendar.current.startOfDay(for: Date())

        let reminder = Reminder(title: "Test", dueDate: today)

        XCTAssertFalse(reminder.isOverdue)
    }

    func test_isOverdue_dueTodayWithTime_returnsFalse() {
        // Even if the time has passed, something due "today" shouldn't be overdue
        let calendar = Calendar.current
        let earlierToday = calendar.date(bySettingHour: 1, minute: 0, second: 0, of: Date())!

        let reminder = Reminder(title: "Test", dueDate: earlierToday)

        XCTAssertFalse(reminder.isOverdue)
    }

    func test_isOverdue_dueTomorrow_returnsFalse() {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date())!

        let reminder = Reminder(title: "Test", dueDate: tomorrow)

        XCTAssertFalse(reminder.isOverdue)
    }

    func test_isOverdue_completed_returnsFalse() {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!

        let reminder = Reminder(title: "Test", dueDate: yesterday, isCompleted: true)

        XCTAssertFalse(reminder.isOverdue)
    }

    func test_isOverdue_noDueDate_returnsFalse() {
        let reminder = Reminder(title: "Test", dueDate: nil)

        XCTAssertFalse(reminder.isOverdue)
    }

    // MARK: - isDueToday Tests

    func test_isDueToday_todayAtMidnight_returnsTrue() {
        let today = Calendar.current.startOfDay(for: Date())

        let reminder = Reminder(title: "Test", dueDate: today)

        XCTAssertTrue(reminder.isDueToday)
    }

    func test_isDueToday_todayAt3PM_returnsTrue() {
        let calendar = Calendar.current
        let todayAt3PM = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: Date())!

        let reminder = Reminder(title: "Test", dueDate: todayAt3PM)

        XCTAssertTrue(reminder.isDueToday)
    }

    func test_isDueToday_yesterday_returnsFalse() {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!

        let reminder = Reminder(title: "Test", dueDate: yesterday)

        XCTAssertFalse(reminder.isDueToday)
    }

    // MARK: - daysUntilDue Tests

    func test_daysUntilDue_today_returnsZero() {
        let today = Calendar.current.startOfDay(for: Date())

        let reminder = Reminder(title: "Test", dueDate: today)

        XCTAssertEqual(reminder.daysUntilDue, 0)
    }

    func test_daysUntilDue_tomorrow_returnsOne() {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date())!

        let reminder = Reminder(title: "Test", dueDate: tomorrow)

        XCTAssertEqual(reminder.daysUntilDue, 1)
    }

    func test_daysUntilDue_yesterday_returnsNegativeOne() {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!

        let reminder = Reminder(title: "Test", dueDate: yesterday)

        XCTAssertEqual(reminder.daysUntilDue, -1)
    }

    func test_daysUntilDue_noDueDate_returnsNil() {
        let reminder = Reminder(title: "Test", dueDate: nil)

        XCTAssertNil(reminder.daysUntilDue)
    }
}

final class RecurrenceTests: XCTestCase {

    // MARK: - Daily Recurrence

    func test_dailyRecurrence_nextDateFromToday_returnsTomorrow() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let expectedTomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        let nextDate = RecurrenceType.daily.nextDate(from: today)

        XCTAssertEqual(nextDate, expectedTomorrow)
    }

    // MARK: - Weekly Recurrence

    func test_weeklyRecurrence_nextDateFromToday_returnsNextWeek() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let expectedNextWeek = calendar.date(byAdding: .day, value: 7, to: today)!

        let nextDate = RecurrenceType.weekly.nextDate(from: today)

        XCTAssertEqual(nextDate, expectedNextWeek)
    }

    // MARK: - Monthly Recurrence

    func test_monthlyRecurrence_nextDateFromToday_returnsNextMonth() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let expectedNextMonth = calendar.date(byAdding: .month, value: 1, to: today)!

        let nextDate = RecurrenceType.monthly.nextDate(from: today)

        XCTAssertEqual(nextDate, expectedNextMonth)
    }

    // MARK: - None Recurrence

    func test_noneRecurrence_nextDate_returnsNil() {
        let today = Calendar.current.startOfDay(for: Date())

        let nextDate = RecurrenceType.none.nextDate(from: today)

        XCTAssertNil(nextDate)
    }
}

final class CreateNextOccurrenceTests: XCTestCase {

    func test_createNextOccurrence_dailyRecurring_createsNextDay() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let reminder = Reminder(
            title: "Daily task",
            dueDate: today,
            recurrence: .daily
        )

        let next = reminder.createNextOccurrence()

        XCTAssertNotNil(next)
        XCTAssertEqual(next?.title, "Daily task")
        XCTAssertEqual(next?.isCompleted, false)

        if let nextDueDate = next?.dueDate {
            let expectedTomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
            XCTAssertTrue(calendar.isDate(nextDueDate, inSameDayAs: expectedTomorrow))
        }
    }

    func test_createNextOccurrence_overdueRecurring_createsFromToday() {
        // If a daily reminder was due 3 days ago, next occurrence should be tomorrow (not 2 days ago)
        let calendar = Calendar.current
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: Date())!
        let today = calendar.startOfDay(for: Date())
        let expectedTomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        let reminder = Reminder(
            title: "Overdue task",
            dueDate: threeDaysAgo,
            recurrence: .daily
        )

        let next = reminder.createNextOccurrence()

        XCTAssertNotNil(next)
        if let nextDueDate = next?.dueDate {
            // Should be tomorrow, not 2 days ago
            XCTAssertTrue(calendar.isDate(nextDueDate, inSameDayAs: expectedTomorrow))
        }
    }

    func test_createNextOccurrence_nonRecurring_returnsNil() {
        let reminder = Reminder(
            title: "One-time task",
            dueDate: Date(),
            recurrence: .none
        )

        let next = reminder.createNextOccurrence()

        XCTAssertNil(next)
    }

    func test_createNextOccurrence_noDueDate_returnsNil() {
        let reminder = Reminder(
            title: "No date task",
            dueDate: nil,
            recurrence: .daily
        )

        let next = reminder.createNextOccurrence()

        XCTAssertNil(next)
    }
}
