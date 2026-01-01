import SwiftUI

struct HabitHeatmapView: View {
    let habit: Reminder
    let weeks: Int

    private let calendar = Calendar.current
    private let squareSize: CGFloat = 10
    private let spacing: CGFloat = 2

    init(habit: Reminder, weeks: Int = 12) {
        self.habit = habit
        self.weeks = weeks
    }

    private var dates: [[Date]] {
        // Generate dates for the heatmap grid (columns = weeks, rows = days of week)
        var result: [[Date]] = Array(repeating: [], count: 7)
        let today = calendar.startOfDay(for: Date())

        // Find the most recent Sunday to align the grid
        let weekday = calendar.component(.weekday, from: today)
        let daysToSubtract = (weeks * 7) - 1 + (weekday - 1)

        guard let startDate = calendar.date(byAdding: .day, value: -daysToSubtract, to: today) else {
            return result
        }

        var currentDate = startDate
        while currentDate <= today {
            let dayOfWeek = calendar.component(.weekday, from: currentDate) - 1 // 0 = Sunday
            result[dayOfWeek].append(currentDate)
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }

        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
            // Header with stats
            HStack {
                Text(habit.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text("\(habit.completionCount(days: weeks * 7)) days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Heatmap grid
            HStack(alignment: .top, spacing: spacing) {
                // Day labels
                VStack(alignment: .trailing, spacing: spacing) {
                    ForEach(0..<7, id: \.self) { dayIndex in
                        if dayIndex == 1 || dayIndex == 3 || dayIndex == 5 {
                            Text(dayLabel(for: dayIndex))
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                                .frame(height: squareSize)
                        } else {
                            Text("")
                                .font(.system(size: 8))
                                .frame(height: squareSize)
                        }
                    }
                }

                // Grid of squares
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: spacing) {
                        ForEach(0..<weeks, id: \.self) { weekIndex in
                            VStack(spacing: spacing) {
                                ForEach(0..<7, id: \.self) { dayIndex in
                                    let dateIndex = weekIndex
                                    if dateIndex < dates[dayIndex].count {
                                        let date = dates[dayIndex][dateIndex]
                                        DaySquare(
                                            date: date,
                                            isCompleted: habit.wasCompletedOn(date: date),
                                            isToday: calendar.isDateInToday(date),
                                            isFuture: date > Date()
                                        )
                                        .frame(width: squareSize, height: squareSize)
                                    } else {
                                        Rectangle()
                                            .fill(Color.clear)
                                            .frame(width: squareSize, height: squareSize)
                                    }
                                }
                            }
                        }
                    }
                }

                // Month labels would go here but keeping it simple
            }

            // Streak info
            HStack(spacing: Constants.Spacing.md) {
                Label("\(currentStreak) day streak", systemImage: "flame.fill")
                    .font(.caption)
                    .foregroundStyle(currentStreak > 0 ? .orange : .secondary)

                Spacer()

                HStack(spacing: 4) {
                    Text("Less")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    ForEach([0.0, 0.3, 0.6, 1.0], id: \.self) { opacity in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(opacity == 0 ? Color.secondary.opacity(0.2) : Color.green.opacity(opacity))
                            .frame(width: 8, height: 8)
                    }
                    Text("More")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(Constants.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Constants.CornerRadius.sm)
                .fill(Color.green.opacity(0.08))
        )
    }

    private func dayLabel(for index: Int) -> String {
        let days = ["S", "M", "T", "W", "T", "F", "S"]
        return days[index]
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
}

struct DaySquare: View {
    let date: Date
    let isCompleted: Bool
    let isToday: Bool
    let isFuture: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(squareColor)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(isToday ? Color.primary.opacity(0.5) : Color.clear, lineWidth: 1)
            )
    }

    private var squareColor: Color {
        if isFuture {
            return Color.clear
        } else if isCompleted {
            return Color.green
        } else {
            return Color.secondary.opacity(0.2)
        }
    }
}

// Compact version for the habits section
struct HabitMiniHeatmap: View {
    let habit: Reminder
    let days: Int

    private let calendar = Calendar.current
    private let squareSize: CGFloat = 6
    private let spacing: CGFloat = 1

    init(habit: Reminder, days: Int = 30) {
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
                RoundedRectangle(cornerRadius: 1)
                    .fill(habit.wasCompletedOn(date: date) ? Color.green : Color.secondary.opacity(0.2))
                    .frame(width: squareSize, height: squareSize)
            }
        }
    }
}

#Preview {
    VStack {
        HabitHeatmapView(habit: {
            let habit = Reminder(title: "Exercise", category: nil)
            // Add some sample completion dates
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
