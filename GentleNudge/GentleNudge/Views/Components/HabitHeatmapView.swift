import SwiftUI

// MARK: - Main Habit Heatmap (Interactive)
struct HabitHeatmapView: View {
    @Bindable var habit: Reminder
    let weeks: Int

    @State private var showingHistoryEditor = false

    private let calendar = Calendar.current

    init(habit: Reminder, weeks: Int = 12) {
        self.habit = habit
        self.weeks = weeks
    }

    private var currentStreak: Int {
        var streak = 0
        var checkDate = calendar.startOfDay(for: Date())

        // If not completed today, start from yesterday
        if !habit.wasCompletedOn(date: checkDate) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: checkDate) else {
                return 0
            }
            checkDate = yesterday
        }

        while habit.wasCompletedOn(date: checkDate) {
            streak += 1
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: checkDate) else {
                break
            }
            checkDate = previousDay
        }

        return streak
    }

    private var totalDays: Int {
        weeks * 7
    }

    private var completionRate: Double {
        let completed = habit.completionCount(days: totalDays)
        return totalDays > 0 ? Double(completed) / Double(totalDays) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
            // Header
            HStack {
                Text(habit.title)
                    .font(.headline)
                Spacer()
                Button {
                    showingHistoryEditor = true
                } label: {
                    Label("Edit History", systemImage: "calendar.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }

            // Stats row
            HStack(spacing: Constants.Spacing.lg) {
                StatBadge(
                    icon: "flame.fill",
                    value: "\(currentStreak)",
                    label: "streak",
                    color: currentStreak > 0 ? .orange : .gray
                )

                StatBadge(
                    icon: "checkmark.circle.fill",
                    value: "\(habit.completionCount(days: totalDays))",
                    label: "of \(totalDays) days",
                    color: .green
                )

                StatBadge(
                    icon: "percent",
                    value: "\(Int(completionRate * 100))%",
                    label: "rate",
                    color: .blue
                )
            }

            // Last 8 weeks as a simple grid
            RecentWeeksGrid(habit: habit, weeks: 8)

            // Legend
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 8, height: 8)
                    Text("Missed")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .padding(.leading, 8)
                    Text("Done")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(Constants.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Constants.CornerRadius.md)
                .fill(Color.green.opacity(0.08))
        )
        .sheet(isPresented: $showingHistoryEditor) {
            HabitHistoryEditor(habit: habit)
        }
    }
}

// MARK: - Stat Badge
struct StatBadge: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Recent Weeks Grid (Calendar-style)
struct RecentWeeksGrid: View {
    let habit: Reminder
    let weeks: Int

    private let calendar = Calendar.current
    private let daySize: CGFloat = 12
    private let spacing: CGFloat = 3

    private var gridData: [[Date?]] {
        // Create a grid: rows = weeks (most recent at bottom), columns = days (Sun-Sat)
        let today = calendar.startOfDay(for: Date())
        var grid: [[Date?]] = []

        for weekOffset in (0..<weeks).reversed() {
            var week: [Date?] = Array(repeating: nil, count: 7)

            for dayOfWeek in 0..<7 {
                // Calculate the date for this cell
                let todayWeekday = calendar.component(.weekday, from: today) - 1 // 0 = Sunday
                let daysFromToday = (weekOffset * 7) + (todayWeekday - dayOfWeek)

                if daysFromToday >= 0 {
                    if let date = calendar.date(byAdding: .day, value: -daysFromToday, to: today) {
                        week[dayOfWeek] = date
                    }
                }
            }

            grid.append(week)
        }

        return grid
    }

    var body: some View {
        VStack(spacing: spacing) {
            // Day labels
            HStack(spacing: spacing) {
                ForEach(["S", "M", "T", "W", "T", "F", "S"], id: \.self) { day in
                    Text(day)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: daySize)
                }
            }

            // Grid
            ForEach(Array(gridData.enumerated()), id: \.offset) { _, week in
                HStack(spacing: spacing) {
                    ForEach(0..<7, id: \.self) { dayIndex in
                        if let date = week[dayIndex] {
                            DayCell(
                                date: date,
                                isCompleted: habit.wasCompletedOn(date: date),
                                isToday: calendar.isDateInToday(date)
                            )
                            .frame(width: daySize, height: daySize)
                        } else {
                            Color.clear
                                .frame(width: daySize, height: daySize)
                        }
                    }
                }
            }
        }
    }
}

struct DayCell: View {
    let date: Date
    let isCompleted: Bool
    let isToday: Bool

    var body: some View {
        Circle()
            .fill(isCompleted ? Color.green : Color.secondary.opacity(0.2))
            .overlay(
                Circle()
                    .strokeBorder(isToday ? Color.primary : Color.clear, lineWidth: 1.5)
            )
    }
}

// MARK: - Habit History Editor (Full Screen)
struct HabitHistoryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var habit: Reminder

    @State private var displayedMonth: Date = Date()

    private let calendar = Calendar.current

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Month navigation
                HStack {
                    Button {
                        withAnimation {
                            displayedMonth = calendar.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.title3)
                    }

                    Spacer()

                    Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                        .font(.title2)
                        .fontWeight(.semibold)

                    Spacer()

                    Button {
                        withAnimation {
                            let nextMonth = calendar.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
                            // Don't go past current month
                            if nextMonth <= Date() {
                                displayedMonth = nextMonth
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.title3)
                    }
                    .disabled(calendar.isDate(displayedMonth, equalTo: Date(), toGranularity: .month))
                }
                .padding()

                // Calendar grid
                CalendarMonthView(
                    habit: habit,
                    month: displayedMonth,
                    onToggle: { date in
                        toggleCompletion(for: date)
                    }
                )
                .padding(.horizontal)

                Spacer()

                // Instructions
                Text("Tap a day to mark it as done or not done")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
            }
            .navigationTitle("Edit \(habit.title) History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func toggleCompletion(for date: Date) {
        let startOfDay = calendar.startOfDay(for: date)

        // Don't allow future dates
        guard startOfDay <= calendar.startOfDay(for: Date()) else { return }

        if habit.wasCompletedOn(date: startOfDay) {
            // Remove completion
            habit.habitCompletionDates.removeAll { calendar.isDate($0, inSameDayAs: startOfDay) }
        } else {
            // Add completion
            habit.habitCompletionDates.append(startOfDay)
        }

        HapticManager.impact(.light)
    }
}

// MARK: - Calendar Month View
struct CalendarMonthView: View {
    let habit: Reminder
    let month: Date
    let onToggle: (Date) -> Void

    private let calendar = Calendar.current
    private let daySize: CGFloat = 44
    private let spacing: CGFloat = 4

    private var daysInMonth: [Date?] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: month),
              let firstWeek = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start) else {
            return []
        }

        var days: [Date?] = []
        var currentDate = firstWeek.start

        // Get all days that should appear in the calendar grid
        // Continue until we reach Sunday after month end (to complete the week)
        while currentDate < monthInterval.end || calendar.component(.weekday, from: currentDate) != 1 {
            if currentDate >= monthInterval.start && currentDate < monthInterval.end {
                days.append(currentDate)
            } else {
                days.append(nil) // Placeholder for days outside the month
            }
            guard let nextDate = calendar.date(byAdding: .day, value: 1, to: currentDate) else { break }
            currentDate = nextDate

            // Safety limit (max 6 weeks)
            if days.count > 42 { break }
        }

        return days
    }

    var body: some View {
        VStack(spacing: spacing) {
            // Day of week headers
            HStack(spacing: spacing) {
                ForEach(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], id: \.self) { day in
                    Text(day)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .frame(width: daySize)
                }
            }

            // Calendar grid
            let columns = Array(repeating: GridItem(.fixed(daySize), spacing: spacing), count: 7)

            LazyVGrid(columns: columns, spacing: spacing) {
                ForEach(Array(daysInMonth.enumerated()), id: \.offset) { _, date in
                    if let date = date {
                        CalendarDayButton(
                            date: date,
                            isCompleted: habit.wasCompletedOn(date: date),
                            isToday: calendar.isDateInToday(date),
                            isFuture: date > Date(),
                            onToggle: { onToggle(date) }
                        )
                        .frame(width: daySize, height: daySize)
                    } else {
                        Color.clear
                            .frame(width: daySize, height: daySize)
                    }
                }
            }
        }
    }
}

struct CalendarDayButton: View {
    let date: Date
    let isCompleted: Bool
    let isToday: Bool
    let isFuture: Bool
    let onToggle: () -> Void

    private let calendar = Calendar.current

    var body: some View {
        Button(action: onToggle) {
            ZStack {
                // Background
                Circle()
                    .fill(backgroundColor)

                // Day number
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 14, weight: isToday ? .bold : .regular))
                    .foregroundStyle(textColor)

                // Today indicator
                if isToday {
                    Circle()
                        .strokeBorder(Color.primary, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .opacity(isFuture ? 0.3 : 1)
    }

    private var backgroundColor: Color {
        if isCompleted {
            return .green
        } else if isFuture {
            return Color.secondary.opacity(0.1)
        } else {
            return Color.secondary.opacity(0.15)
        }
    }

    private var textColor: Color {
        if isCompleted {
            return .white
        } else if isFuture {
            return .secondary
        } else {
            return .primary
        }
    }
}

// MARK: - Compact Mini Heatmap (for habit list)
struct HabitMiniHeatmap: View {
    let habit: Reminder
    let days: Int

    private let calendar = Calendar.current
    private let squareSize: CGFloat = 6
    private let spacing: CGFloat = 2

    init(habit: Reminder, days: Int = 14) {
        self.habit = habit
        self.days = days
    }

    private var recentDates: [Date] {
        let today = calendar.startOfDay(for: Date())
        return (0..<days).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today)
        }.reversed()
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(recentDates, id: \.self) { date in
                Circle()
                    .fill(habit.wasCompletedOn(date: date) ? Color.green : Color.secondary.opacity(0.2))
                    .frame(width: squareSize, height: squareSize)
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        HabitHeatmapView(habit: {
            let habit = Reminder(title: "Exercise", category: nil)
            let calendar = Calendar.current
            for i in [0, 1, 2, 4, 5, 7, 8, 9, 12, 14, 15, 16, 17, 20, 21] {
                if let date = calendar.date(byAdding: .day, value: -i, to: Date()) {
                    habit.habitCompletionDates.append(calendar.startOfDay(for: date))
                }
            }
            return habit
        }())
        .padding()

        HabitMiniHeatmap(habit: {
            let habit = Reminder(title: "Read", category: nil)
            let calendar = Calendar.current
            for i in [0, 1, 3, 5, 6, 7, 10, 12, 15] {
                if let date = calendar.date(byAdding: .day, value: -i, to: Date()) {
                    habit.habitCompletionDates.append(calendar.startOfDay(for: date))
                }
            }
            return habit
        }())
        .padding()
    }
}
