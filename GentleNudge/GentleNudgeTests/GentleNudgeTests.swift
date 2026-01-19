//
//  GentleNudgeTests.swift
//  GentleNudgeTests
//
//  Created by Horia Galatanu on 12/27/25.
//

import XCTest
@testable import GentleNudge_iOS

// MARK: - Reminder isOverdue Tests

final class ReminderIsOverdueTests: XCTestCase {

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

    func test_isOverdue_dueOneWeekAgo_returnsTrue() {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date())!

        let reminder = Reminder(title: "Test", dueDate: weekAgo)

        XCTAssertTrue(reminder.isOverdue)
    }
}

// MARK: - Reminder isDueToday Tests

final class ReminderIsDueTodayTests: XCTestCase {

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

    func test_isDueToday_todayAt1159PM_returnsTrue() {
        let calendar = Calendar.current
        let todayLate = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: Date())!

        let reminder = Reminder(title: "Test", dueDate: todayLate)

        XCTAssertTrue(reminder.isDueToday)
    }

    func test_isDueToday_yesterday_returnsFalse() {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!

        let reminder = Reminder(title: "Test", dueDate: yesterday)

        XCTAssertFalse(reminder.isDueToday)
    }

    func test_isDueToday_tomorrow_returnsFalse() {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date())!

        let reminder = Reminder(title: "Test", dueDate: tomorrow)

        XCTAssertFalse(reminder.isDueToday)
    }

    func test_isDueToday_noDueDate_returnsFalse() {
        let reminder = Reminder(title: "Test", dueDate: nil)

        XCTAssertFalse(reminder.isDueToday)
    }
}

// MARK: - Reminder isDueTomorrow Tests

final class ReminderIsDueTomorrowTests: XCTestCase {

    func test_isDueTomorrow_tomorrow_returnsTrue() {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date())!

        let reminder = Reminder(title: "Test", dueDate: tomorrow)

        XCTAssertTrue(reminder.isDueTomorrow)
    }

    func test_isDueTomorrow_today_returnsFalse() {
        let reminder = Reminder(title: "Test", dueDate: Date())

        XCTAssertFalse(reminder.isDueTomorrow)
    }

    func test_isDueTomorrow_dayAfterTomorrow_returnsFalse() {
        let calendar = Calendar.current
        let dayAfter = calendar.date(byAdding: .day, value: 2, to: Date())!

        let reminder = Reminder(title: "Test", dueDate: dayAfter)

        XCTAssertFalse(reminder.isDueTomorrow)
    }

    func test_isDueTomorrow_noDueDate_returnsFalse() {
        let reminder = Reminder(title: "Test", dueDate: nil)

        XCTAssertFalse(reminder.isDueTomorrow)
    }
}

// MARK: - Reminder daysUntilDue Tests

final class ReminderDaysUntilDueTests: XCTestCase {

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

    func test_daysUntilDue_oneWeekFromNow_returnsSeven() {
        let calendar = Calendar.current
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: Date()))!

        let reminder = Reminder(title: "Test", dueDate: nextWeek)

        XCTAssertEqual(reminder.daysUntilDue, 7)
    }

    func test_daysUntilDue_oneWeekAgo_returnsNegativeSeven() {
        let calendar = Calendar.current
        let lastWeek = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: Date()))!

        let reminder = Reminder(title: "Test", dueDate: lastWeek)

        XCTAssertEqual(reminder.daysUntilDue, -7)
    }

    func test_daysUntilDue_noDueDate_returnsNil() {
        let reminder = Reminder(title: "Test", dueDate: nil)

        XCTAssertNil(reminder.daysUntilDue)
    }
}

// MARK: - Reminder daysUntilDueText Tests

final class ReminderDaysUntilDueTextTests: XCTestCase {

    func test_daysUntilDueText_today_returnsToday() {
        let today = Calendar.current.startOfDay(for: Date())

        let reminder = Reminder(title: "Test", dueDate: today)

        XCTAssertEqual(reminder.daysUntilDueText, "Today")
    }

    func test_daysUntilDueText_tomorrow_returnsTomorrow() {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!

        let reminder = Reminder(title: "Test", dueDate: tomorrow)

        XCTAssertEqual(reminder.daysUntilDueText, "Tomorrow")
    }

    func test_daysUntilDueText_yesterday_returnsYesterday() {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))!

        let reminder = Reminder(title: "Test", dueDate: yesterday)

        XCTAssertEqual(reminder.daysUntilDueText, "Yesterday")
    }

    func test_daysUntilDueText_threeDaysFromNow_returnsInThreeDays() {
        let calendar = Calendar.current
        let threeDays = calendar.date(byAdding: .day, value: 3, to: calendar.startOfDay(for: Date()))!

        let reminder = Reminder(title: "Test", dueDate: threeDays)

        XCTAssertEqual(reminder.daysUntilDueText, "in 3 days")
    }

    func test_daysUntilDueText_threeDaysAgo_returnsThreeDaysAgo() {
        let calendar = Calendar.current
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: Date()))!

        let reminder = Reminder(title: "Test", dueDate: threeDaysAgo)

        XCTAssertEqual(reminder.daysUntilDueText, "3 days ago")
    }

    func test_daysUntilDueText_noDueDate_returnsNil() {
        let reminder = Reminder(title: "Test", dueDate: nil)

        XCTAssertNil(reminder.daysUntilDueText)
    }
}

// MARK: - Reminder formattedDueDate Tests

final class ReminderFormattedDueDateTests: XCTestCase {

    func test_formattedDueDate_today_returnsToday() {
        let reminder = Reminder(title: "Test", dueDate: Date())

        XCTAssertEqual(reminder.formattedDueDate, "Today")
    }

    func test_formattedDueDate_tomorrow_returnsTomorrow() {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date())!

        let reminder = Reminder(title: "Test", dueDate: tomorrow)

        XCTAssertEqual(reminder.formattedDueDate, "Tomorrow")
    }

    func test_formattedDueDate_overdue_containsOverdue() {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!

        let reminder = Reminder(title: "Test", dueDate: yesterday)

        XCTAssertTrue(reminder.formattedDueDate?.contains("Overdue") ?? false)
    }

    func test_formattedDueDate_noDueDate_returnsNil() {
        let reminder = Reminder(title: "Test", dueDate: nil)

        XCTAssertNil(reminder.formattedDueDate)
    }
}

// MARK: - Reminder isDistantRecurring Tests

final class ReminderIsDistantRecurringTests: XCTestCase {

    func test_isDistantRecurring_recurringFiveDaysOut_returnsTrue() {
        let calendar = Calendar.current
        let fiveDays = calendar.date(byAdding: .day, value: 5, to: Date())!

        let reminder = Reminder(title: "Test", dueDate: fiveDays, recurrence: .weekly)

        XCTAssertTrue(reminder.isDistantRecurring)
    }

    func test_isDistantRecurring_recurringTomorrow_returnsFalse() {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date())!

        let reminder = Reminder(title: "Test", dueDate: tomorrow, recurrence: .weekly)

        XCTAssertFalse(reminder.isDistantRecurring)
    }

    func test_isDistantRecurring_recurringThreeDays_returnsFalse() {
        let calendar = Calendar.current
        let threeDays = calendar.date(byAdding: .day, value: 3, to: Date())!

        let reminder = Reminder(title: "Test", dueDate: threeDays, recurrence: .weekly)

        XCTAssertFalse(reminder.isDistantRecurring)
    }

    func test_isDistantRecurring_nonRecurringFiveDays_returnsFalse() {
        let calendar = Calendar.current
        let fiveDays = calendar.date(byAdding: .day, value: 5, to: Date())!

        let reminder = Reminder(title: "Test", dueDate: fiveDays, recurrence: .none)

        XCTAssertFalse(reminder.isDistantRecurring)
    }

    func test_isDistantRecurring_noDueDate_returnsFalse() {
        let reminder = Reminder(title: "Test", dueDate: nil, recurrence: .weekly)

        XCTAssertFalse(reminder.isDistantRecurring)
    }
}

// MARK: - Reminder Completion Tests

final class ReminderCompletionTests: XCTestCase {

    func test_markCompleted_setsIsCompletedTrue() {
        let reminder = Reminder(title: "Test")

        reminder.markCompleted()

        XCTAssertTrue(reminder.isCompleted)
    }

    func test_markCompleted_setsCompletedAt() {
        let reminder = Reminder(title: "Test")

        reminder.markCompleted()

        XCTAssertNotNil(reminder.completedAt)
    }

    func test_markIncomplete_setsIsCompletedFalse() {
        let reminder = Reminder(title: "Test", isCompleted: true)

        reminder.markIncomplete()

        XCTAssertFalse(reminder.isCompleted)
    }

    func test_markIncomplete_clearsCompletedAt() {
        let reminder = Reminder(title: "Test", isCompleted: true)
        reminder.completedAt = Date()

        reminder.markIncomplete()

        XCTAssertNil(reminder.completedAt)
    }

    func test_isCompletedToday_completedNow_returnsTrue() {
        let reminder = Reminder(title: "Test")
        reminder.completedAt = Date()

        XCTAssertTrue(reminder.isCompletedToday)
    }

    func test_isCompletedToday_completedYesterday_returnsFalse() {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!

        let reminder = Reminder(title: "Test")
        reminder.completedAt = yesterday

        XCTAssertFalse(reminder.isCompletedToday)
    }

    func test_isCompletedToday_notCompleted_returnsFalse() {
        let reminder = Reminder(title: "Test")

        XCTAssertFalse(reminder.isCompletedToday)
    }
}

// MARK: - Recurrence Type Tests

final class RecurrenceTypeTests: XCTestCase {

    func test_dailyRecurrence_nextDateFromToday_returnsTomorrow() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let expectedTomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        let nextDate = RecurrenceType.daily.nextDate(from: today)

        XCTAssertEqual(nextDate, expectedTomorrow)
    }

    func test_weeklyRecurrence_nextDateFromToday_returnsNextWeek() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let expectedNextWeek = calendar.date(byAdding: .day, value: 7, to: today)!

        let nextDate = RecurrenceType.weekly.nextDate(from: today)

        XCTAssertEqual(nextDate, expectedNextWeek)
    }

    func test_biweeklyRecurrence_nextDateFromToday_returnsTwoWeeks() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let expectedDate = calendar.date(byAdding: .weekOfYear, value: 2, to: today)!

        let nextDate = RecurrenceType.biweekly.nextDate(from: today)

        XCTAssertEqual(nextDate, expectedDate)
    }

    func test_monthlyRecurrence_nextDateFromToday_returnsNextMonth() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let expectedNextMonth = calendar.date(byAdding: .month, value: 1, to: today)!

        let nextDate = RecurrenceType.monthly.nextDate(from: today)

        XCTAssertEqual(nextDate, expectedNextMonth)
    }

    func test_quarterlyRecurrence_nextDateFromToday_returnsThreeMonths() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let expectedDate = calendar.date(byAdding: .month, value: 3, to: today)!

        let nextDate = RecurrenceType.quarterly.nextDate(from: today)

        XCTAssertEqual(nextDate, expectedDate)
    }

    func test_semiannuallyRecurrence_nextDateFromToday_returnsSixMonths() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let expectedDate = calendar.date(byAdding: .month, value: 6, to: today)!

        let nextDate = RecurrenceType.semiannually.nextDate(from: today)

        XCTAssertEqual(nextDate, expectedDate)
    }

    func test_yearlyRecurrence_nextDateFromToday_returnsNextYear() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let expectedDate = calendar.date(byAdding: .year, value: 1, to: today)!

        let nextDate = RecurrenceType.yearly.nextDate(from: today)

        XCTAssertEqual(nextDate, expectedDate)
    }

    func test_noneRecurrence_nextDate_returnsNil() {
        let today = Calendar.current.startOfDay(for: Date())

        let nextDate = RecurrenceType.none.nextDate(from: today)

        XCTAssertNil(nextDate)
    }

    func test_weekdaysRecurrence_fromFriday_skipsWeekend() {
        let calendar = Calendar.current
        // Find next Friday
        var friday = Date()
        while calendar.component(.weekday, from: friday) != 6 { // 6 = Friday
            friday = calendar.date(byAdding: .day, value: 1, to: friday)!
        }
        friday = calendar.startOfDay(for: friday)

        let nextDate = RecurrenceType.weekdays.nextDate(from: friday)!

        // Should be Monday (skip Saturday and Sunday)
        let weekday = calendar.component(.weekday, from: nextDate)
        XCTAssertEqual(weekday, 2) // 2 = Monday
    }

    func test_weekdaysRecurrence_fromMonday_returnsTuesday() {
        let calendar = Calendar.current
        // Find next Monday
        var monday = Date()
        while calendar.component(.weekday, from: monday) != 2 { // 2 = Monday
            monday = calendar.date(byAdding: .day, value: 1, to: monday)!
        }
        monday = calendar.startOfDay(for: monday)

        let nextDate = RecurrenceType.weekdays.nextDate(from: monday)!

        let weekday = calendar.component(.weekday, from: nextDate)
        XCTAssertEqual(weekday, 3) // 3 = Tuesday
    }

    func test_weekendsRecurrence_fromSaturday_returnsSunday() {
        let calendar = Calendar.current
        // Find next Saturday
        var saturday = Date()
        while calendar.component(.weekday, from: saturday) != 7 { // 7 = Saturday
            saturday = calendar.date(byAdding: .day, value: 1, to: saturday)!
        }
        saturday = calendar.startOfDay(for: saturday)

        let nextDate = RecurrenceType.weekends.nextDate(from: saturday)!

        let weekday = calendar.component(.weekday, from: nextDate)
        XCTAssertEqual(weekday, 1) // 1 = Sunday
    }

    func test_weekendsRecurrence_fromFriday_returnsSaturday() {
        let calendar = Calendar.current
        // Find next Friday
        var friday = Date()
        while calendar.component(.weekday, from: friday) != 6 { // 6 = Friday
            friday = calendar.date(byAdding: .day, value: 1, to: friday)!
        }
        friday = calendar.startOfDay(for: friday)

        let nextDate = RecurrenceType.weekends.nextDate(from: friday)!

        let weekday = calendar.component(.weekday, from: nextDate)
        XCTAssertEqual(weekday, 7) // 7 = Saturday
    }
}

// MARK: - Recurrence Type Labels Tests

final class RecurrenceTypeLabelTests: XCTestCase {

    func test_noneLabel() {
        XCTAssertEqual(RecurrenceType.none.label, "None")
    }

    func test_dailyLabel() {
        XCTAssertEqual(RecurrenceType.daily.label, "Daily")
    }

    func test_weekdaysLabel() {
        XCTAssertEqual(RecurrenceType.weekdays.label, "Weekdays")
    }

    func test_weekendsLabel() {
        XCTAssertEqual(RecurrenceType.weekends.label, "Weekends")
    }

    func test_weeklyLabel() {
        XCTAssertEqual(RecurrenceType.weekly.label, "Weekly")
    }

    func test_biweeklyLabel() {
        XCTAssertEqual(RecurrenceType.biweekly.label, "Every 2 Weeks")
    }

    func test_monthlyLabel() {
        XCTAssertEqual(RecurrenceType.monthly.label, "Monthly")
    }

    func test_quarterlyLabel() {
        XCTAssertEqual(RecurrenceType.quarterly.label, "Every 3 Months")
    }

    func test_semiannuallyLabel() {
        XCTAssertEqual(RecurrenceType.semiannually.label, "Every 6 Months")
    }

    func test_yearlyLabel() {
        XCTAssertEqual(RecurrenceType.yearly.label, "Yearly")
    }
}

// MARK: - Create Next Occurrence Tests

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

    func test_createNextOccurrence_weeklyRecurring_createsNextWeek() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let reminder = Reminder(
            title: "Weekly task",
            dueDate: today,
            recurrence: .weekly
        )

        let next = reminder.createNextOccurrence()

        XCTAssertNotNil(next)
        if let nextDueDate = next?.dueDate {
            let expectedNextWeek = calendar.date(byAdding: .day, value: 7, to: today)!
            XCTAssertTrue(calendar.isDate(nextDueDate, inSameDayAs: expectedNextWeek))
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

    func test_createNextOccurrence_preservesCategory() {
        let category = Category(name: "Work", icon: "briefcase.fill", colorName: "blue")
        let reminder = Reminder(
            title: "Work task",
            dueDate: Date(),
            category: category,
            recurrence: .daily
        )

        let next = reminder.createNextOccurrence()

        XCTAssertEqual(next?.category?.name, "Work")
    }

    func test_createNextOccurrence_preservesPriority() {
        let reminder = Reminder(
            title: "Urgent task",
            dueDate: Date(),
            priority: .urgent,
            recurrence: .daily
        )

        let next = reminder.createNextOccurrence()

        XCTAssertEqual(next?.priority, .urgent)
    }

    func test_createNextOccurrence_preservesNotes() {
        let reminder = Reminder(
            title: "Task with notes",
            notes: "Important details here",
            dueDate: Date(),
            recurrence: .daily
        )

        let next = reminder.createNextOccurrence()

        XCTAssertEqual(next?.notes, "Important details here")
    }

    func test_createNextOccurrence_preservesRecurrence() {
        let reminder = Reminder(
            title: "Monthly task",
            dueDate: Date(),
            recurrence: .monthly
        )

        let next = reminder.createNextOccurrence()

        XCTAssertEqual(next?.recurrence, .monthly)
    }
}

// MARK: - Reminder Priority Tests

final class ReminderPriorityTests: XCTestCase {

    func test_normalPriority_label() {
        XCTAssertEqual(ReminderPriority.normal.label, "Normal")
    }

    func test_urgentPriority_label() {
        XCTAssertEqual(ReminderPriority.urgent.label, "Urgent")
    }

    func test_normalPriority_icon_isNil() {
        XCTAssertNil(ReminderPriority.normal.icon)
    }

    func test_urgentPriority_icon_isNotNil() {
        XCTAssertNotNil(ReminderPriority.urgent.icon)
    }

    func test_reminder_defaultPriority_isNormal() {
        let reminder = Reminder(title: "Test")

        XCTAssertEqual(reminder.priority, .normal)
    }

    func test_reminder_setPriority_works() {
        let reminder = Reminder(title: "Test")

        reminder.priority = .urgent

        XCTAssertEqual(reminder.priority, .urgent)
    }
}

// MARK: - Reminder isRecurring Tests

final class ReminderIsRecurringTests: XCTestCase {

    func test_isRecurring_withNone_returnsFalse() {
        let reminder = Reminder(title: "Test", recurrence: .none)

        XCTAssertFalse(reminder.isRecurring)
    }

    func test_isRecurring_withDaily_returnsTrue() {
        let reminder = Reminder(title: "Test", recurrence: .daily)

        XCTAssertTrue(reminder.isRecurring)
    }

    func test_isRecurring_withWeekly_returnsTrue() {
        let reminder = Reminder(title: "Test", recurrence: .weekly)

        XCTAssertTrue(reminder.isRecurring)
    }

    func test_isRecurring_withMonthly_returnsTrue() {
        let reminder = Reminder(title: "Test", recurrence: .monthly)

        XCTAssertTrue(reminder.isRecurring)
    }

    func test_isRecurring_withYearly_returnsTrue() {
        let reminder = Reminder(title: "Test", recurrence: .yearly)

        XCTAssertTrue(reminder.isRecurring)
    }
}

// MARK: - Reminder formattedRecurrence Tests

final class ReminderFormattedRecurrenceTests: XCTestCase {

    func test_formattedRecurrence_none_returnsNil() {
        let reminder = Reminder(title: "Test", recurrence: .none)

        XCTAssertNil(reminder.formattedRecurrence)
    }

    func test_formattedRecurrence_daily_returnsDaily() {
        let reminder = Reminder(title: "Test", recurrence: .daily)

        XCTAssertEqual(reminder.formattedRecurrence, "Daily")
    }

    func test_formattedRecurrence_weekly_returnsWeekly() {
        let reminder = Reminder(title: "Test", recurrence: .weekly)

        XCTAssertEqual(reminder.formattedRecurrence, "Weekly")
    }
}

// MARK: - Habit Tests

final class HabitTests: XCTestCase {

    func test_isHabit_withHabitsCategory_returnsTrue() {
        let habitsCategory = Category(name: "Habits", icon: "heart.circle.fill", colorName: "red")
        let reminder = Reminder(title: "Exercise", category: habitsCategory)

        XCTAssertTrue(reminder.isHabit)
    }

    func test_isHabit_withOtherCategory_returnsFalse() {
        let workCategory = Category(name: "Work", icon: "briefcase.fill", colorName: "blue")
        let reminder = Reminder(title: "Meeting", category: workCategory)

        XCTAssertFalse(reminder.isHabit)
    }

    func test_isHabit_withNoCategory_returnsFalse() {
        let reminder = Reminder(title: "Task")

        XCTAssertFalse(reminder.isHabit)
    }

    func test_habit_isOverdue_alwaysFalse() {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
        let habitsCategory = Category(name: "Habits", icon: "heart.circle.fill", colorName: "red")

        let reminder = Reminder(title: "Exercise", dueDate: yesterday, category: habitsCategory)

        XCTAssertFalse(reminder.isOverdue)
    }

    func test_markHabitDoneToday_setsCompletedAt() {
        let reminder = Reminder(title: "Exercise")

        reminder.markHabitDoneToday()

        XCTAssertNotNil(reminder.completedAt)
    }

    func test_markHabitDoneToday_addsToCompletionHistory() {
        let reminder = Reminder(title: "Exercise")

        reminder.markHabitDoneToday()

        XCTAssertEqual(reminder.habitCompletionDates.count, 1)
    }

    func test_markHabitDoneToday_twice_onlyAddsOnce() {
        let reminder = Reminder(title: "Exercise")

        reminder.markHabitDoneToday()
        reminder.markHabitDoneToday()

        XCTAssertEqual(reminder.habitCompletionDates.count, 1)
    }

    func test_clearHabitCompletion_clearsCompletedAt() {
        let reminder = Reminder(title: "Exercise")
        reminder.markHabitDoneToday()

        reminder.clearHabitCompletion()

        XCTAssertNil(reminder.completedAt)
    }

    func test_clearHabitCompletion_removesFromHistory() {
        let reminder = Reminder(title: "Exercise")
        reminder.markHabitDoneToday()

        reminder.clearHabitCompletion()

        XCTAssertEqual(reminder.habitCompletionDates.count, 0)
    }

    func test_wasCompletedOn_today_afterMarking_returnsTrue() {
        let reminder = Reminder(title: "Exercise")
        reminder.markHabitDoneToday()

        XCTAssertTrue(reminder.wasCompletedOn(date: Date()))
    }

    func test_wasCompletedOn_yesterday_returnsFalse() {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
        let reminder = Reminder(title: "Exercise")
        reminder.markHabitDoneToday()

        XCTAssertFalse(reminder.wasCompletedOn(date: yesterday))
    }

    func test_completionCount_withThreeCompletions_returnsThree() {
        let calendar = Calendar.current
        let reminder = Reminder(title: "Exercise")

        // Manually add completion dates for the last 3 days
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today)!

        reminder.habitCompletionDates = [today, yesterday, twoDaysAgo]

        XCTAssertEqual(reminder.completionCount(days: 7), 3)
    }

    func test_completionCount_excludesOldCompletions() {
        let calendar = Calendar.current
        let reminder = Reminder(title: "Exercise")

        let today = calendar.startOfDay(for: Date())
        let tenDaysAgo = calendar.date(byAdding: .day, value: -10, to: today)!

        reminder.habitCompletionDates = [today, tenDaysAgo]

        XCTAssertEqual(reminder.completionCount(days: 7), 1)
    }
}

// MARK: - Date Extension Tests

final class DateExtensionTests: XCTestCase {

    func test_startOfDay_returnsCorrectTime() {
        let calendar = Calendar.current
        let date = Date()

        let startOfDay = date.startOfDay

        let components = calendar.dateComponents([.hour, .minute, .second], from: startOfDay)
        XCTAssertEqual(components.hour, 0)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(components.second, 0)
    }

    func test_endOfDay_returnsCorrectTime() {
        let calendar = Calendar.current
        let date = Date()

        let endOfDay = date.endOfDay

        let components = calendar.dateComponents([.hour, .minute, .second], from: endOfDay)
        XCTAssertEqual(components.hour, 23)
        XCTAssertEqual(components.minute, 59)
        XCTAssertEqual(components.second, 59)
    }

    func test_isSameDay_sameDay_returnsTrue() {
        let date1 = Date()
        let calendar = Calendar.current
        let date2 = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date1)!

        XCTAssertTrue(date1.isSameDay(as: date2))
    }

    func test_isSameDay_differentDay_returnsFalse() {
        let date1 = Date()
        let calendar = Calendar.current
        let date2 = calendar.date(byAdding: .day, value: 1, to: date1)!

        XCTAssertFalse(date1.isSameDay(as: date2))
    }

    func test_tomorrow_isOneDayFromNow() {
        let calendar = Calendar.current
        let tomorrow = Date.tomorrow

        XCTAssertTrue(calendar.isDateInTomorrow(tomorrow))
    }

    func test_nextWeek_isSevenDaysFromNow() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let expectedNextWeek = calendar.date(byAdding: .weekOfYear, value: 1, to: today)!

        let nextWeek = Date.nextWeek

        XCTAssertTrue(calendar.isDate(nextWeek, inSameDayAs: expectedNextWeek))
    }
}

// MARK: - String Extension Tests

final class StringExtensionTests: XCTestCase {

    func test_containsURL_withURL_returnsTrue() {
        let string = "Check out https://example.com"

        XCTAssertTrue(string.containsURL)
    }

    func test_containsURL_withoutURL_returnsFalse() {
        let string = "Just a regular string"

        XCTAssertFalse(string.containsURL)
    }

    func test_containsURL_withEmail_returnsTrue() {
        let string = "Contact me at test@example.com"

        XCTAssertTrue(string.containsURL) // NSDataDetector treats emails as links
    }

    func test_extractedURLs_withSingleURL_returnsOne() {
        let string = "Check out https://example.com for more"

        let urls = string.extractedURLs

        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.absoluteString, "https://example.com")
    }

    func test_extractedURLs_withMultipleURLs_returnsAll() {
        let string = "Visit https://example.com and https://test.com"

        let urls = string.extractedURLs

        XCTAssertEqual(urls.count, 2)
    }

    func test_extractedURLs_withNoURLs_returnsEmpty() {
        let string = "No links here"

        let urls = string.extractedURLs

        XCTAssertTrue(urls.isEmpty)
    }

    func test_extractedURLs_withHTTPURL_extractsCorrectly() {
        let string = "Old style http://example.com link"

        let urls = string.extractedURLs

        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.scheme, "http")
    }
}

// MARK: - Category Tests

final class CategoryTests: XCTestCase {

    func test_category_initialization() {
        let category = Category(name: "Test", icon: "star.fill", colorName: "blue")

        XCTAssertEqual(category.name, "Test")
        XCTAssertEqual(category.icon, "star.fill")
        XCTAssertEqual(category.colorName, "blue")
    }

    func test_category_defaultIsDefault_isFalse() {
        let category = Category(name: "Test", icon: "star.fill", colorName: "blue")

        XCTAssertFalse(category.isDefault)
    }

    func test_category_colorMapping_red() {
        let category = Category(name: "Test", icon: "star.fill", colorName: "red")

        XCTAssertEqual(category.color, .red)
    }

    func test_category_colorMapping_blue() {
        let category = Category(name: "Test", icon: "star.fill", colorName: "blue")

        XCTAssertEqual(category.color, .blue)
    }

    func test_category_colorMapping_unknown_returnsGray() {
        let category = Category(name: "Test", icon: "star.fill", colorName: "unknown")

        XCTAssertEqual(category.color, .gray)
    }

    func test_category_defaults_count() {
        let defaults = Category.defaults

        XCTAssertEqual(defaults.count, 10)
    }

    func test_category_defaults_containsHabits() {
        let defaults = Category.defaults

        XCTAssertTrue(defaults.contains { $0.name == "Habits" })
    }

    func test_category_availableColors_count() {
        let colors = Category.availableColors

        XCTAssertEqual(colors.count, 10)
    }

    func test_category_availableIcons_notEmpty() {
        let icons = Category.availableIcons

        XCTAssertFalse(icons.isEmpty)
    }
}

// MARK: - Reminder Initialization Tests

final class ReminderInitializationTests: XCTestCase {

    func test_reminder_defaultValues() {
        let reminder = Reminder(title: "Test")

        XCTAssertEqual(reminder.title, "Test")
        XCTAssertEqual(reminder.notes, "")
        XCTAssertNil(reminder.dueDate)
        XCTAssertEqual(reminder.priority, .normal)
        XCTAssertFalse(reminder.isCompleted)
        XCTAssertNil(reminder.category)
        XCTAssertEqual(reminder.recurrence, .none)
    }

    func test_reminder_customValues() {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date())!
        let category = Category(name: "Work", icon: "briefcase.fill", colorName: "blue")

        let reminder = Reminder(
            title: "Important meeting",
            notes: "Bring documents",
            dueDate: tomorrow,
            priority: .urgent,
            isCompleted: false,
            category: category,
            recurrence: .weekly
        )

        XCTAssertEqual(reminder.title, "Important meeting")
        XCTAssertEqual(reminder.notes, "Bring documents")
        XCTAssertNotNil(reminder.dueDate)
        XCTAssertEqual(reminder.priority, .urgent)
        XCTAssertFalse(reminder.isCompleted)
        XCTAssertEqual(reminder.category?.name, "Work")
        XCTAssertEqual(reminder.recurrence, .weekly)
    }

    func test_reminder_hasUniqueID() {
        let reminder1 = Reminder(title: "Test 1")
        let reminder2 = Reminder(title: "Test 2")

        XCTAssertNotEqual(reminder1.id, reminder2.id)
    }

    func test_reminder_createdAtIsSet() {
        let reminder = Reminder(title: "Test")

        XCTAssertNotNil(reminder.createdAt)
    }
}
