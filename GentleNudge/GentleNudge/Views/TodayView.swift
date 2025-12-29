import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var reminders: [Reminder]
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    // Habits - show all habits (they're never permanently completed)
    private var habitReminders: [Reminder] {
        reminders.filter { $0.isHabit && !$0.isCompleted }
            .sorted { $0.title < $1.title }
    }

    // Urgent: Items due today, overdue, or high priority
    private var needsAttentionReminders: [Reminder] {
        reminders.filter { reminder in
            guard !reminder.isHabit, !reminder.isCompleted else { return false }
            // Include: overdue, due today, or high priority
            return reminder.isOverdue || reminder.isDueToday || reminder.priority == .high
        }
        .sorted { r1, r2 in
            // Overdue first, then due today, then high priority
            if r1.isOverdue != r2.isOverdue { return r1.isOverdue }
            if r1.isDueToday != r2.isDueToday { return r1.isDueToday }
            return r1.priority.rawValue > r2.priority.rawValue
        }
    }

    private func remindersForCategory(_ category: Category) -> [Reminder] {
        reminders.filter { reminder in
            guard reminder.category?.id == category.id,
                  !reminder.isCompleted,
                  !reminder.isHabit else { return false }
            // Exclude items already in Needs Attention
            let inNeedsAttention = reminder.isOverdue || reminder.isDueToday || reminder.priority == .high
            return !inNeedsAttention
        }
        .sorted { $0.priority.rawValue > $1.priority.rawValue }
    }

    // Categories that have reminders (for jump bar)
    private var categoriesWithReminders: [Category] {
        categories.filter { category in
            category.name != "Habits" && !remindersForCategory(category).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Constants.Spacing.sm) {
                        // Category Jump Bar
                        if !categoriesWithReminders.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: Constants.Spacing.sm) {
                                    ForEach(categoriesWithReminders) { category in
                                        Button {
                                            withAnimation {
                                                proxy.scrollTo(category.id, anchor: .top)
                                            }
                                            HapticManager.impact(.light)
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: category.icon)
                                                    .font(.caption)
                                                Text(category.name)
                                                    .font(.caption)
                                                    .fontWeight(.medium)
                                            }
                                            .padding(.horizontal, Constants.Spacing.sm)
                                            .padding(.vertical, Constants.Spacing.xs)
                                            .background(category.color.opacity(0.15))
                                            .foregroundStyle(category.color)
                                            .clipShape(Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, Constants.Spacing.xs)
                            }
                        }

                        // Habits Section - Daily Checklist
                        if !habitReminders.isEmpty {
                            HabitsSection(habits: habitReminders)
                        }

                        // Urgent / Time-sensitive / High Priority
                        if !needsAttentionReminders.isEmpty {
                            VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
                                HStack(spacing: Constants.Spacing.xs) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundStyle(.red)
                                    Text("Needs Attention")
                                        .font(.headline)
                                }

                                VStack(spacing: 4) {
                                    ForEach(needsAttentionReminders) { reminder in
                                        NeedsAttentionRow(reminder: reminder)
                                    }
                                }
                            }
                            .padding(Constants.Spacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: Constants.CornerRadius.md)
                                    .fill(Color.red.opacity(0.06))
                            )
                        }

                        // Categories with reminders
                        ForEach(categories.filter { $0.name != "Habits" }) { category in
                            let categoryReminders = remindersForCategory(category)
                            if !categoryReminders.isEmpty {
                                HomeCategorySection(
                                    category: category,
                                    reminders: categoryReminders
                                )
                                .id(category.id)
                            }
                        }
                    }
                    .padding()
                }
            }
            .background(AppColors.background)
            .navigationTitle("Gentle Nudge")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

// MARK: - Habits Section

struct HabitsSection: View {
    let habits: [Reminder]

    private var completedCount: Int {
        habits.filter { $0.isCompletedToday }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
            HStack {
                Image(systemName: "heart.circle.fill")
                    .foregroundStyle(.red)
                Text("Habits")
                    .font(.headline)
                Spacer()
                Text("\(completedCount)/\(habits.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.red.opacity(0.2))
                        .frame(height: 5)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.red)
                        .frame(width: geo.size.width * CGFloat(completedCount) / CGFloat(max(habits.count, 1)), height: 5)
                        .animation(.spring, value: completedCount)
                }
            }
            .frame(height: 5)

            VStack(spacing: 4) {
                ForEach(habits) { habit in
                    HabitRow(habit: habit)
                }
            }
        }
        .padding(Constants.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Constants.CornerRadius.md)
                .fill(Color.red.opacity(0.06))
        )
    }
}

struct HabitRow: View {
    @Bindable var habit: Reminder

    var isCompletedToday: Bool {
        habit.isCompletedToday
    }

    var body: some View {
        HStack(spacing: Constants.Spacing.sm) {
            Button {
                withAnimation(Constants.Animation.spring) {
                    HapticManager.impact(.medium)
                    if isCompletedToday {
                        habit.clearHabitCompletion()
                    } else {
                        habit.markHabitDoneToday()
                    }
                }
            } label: {
                Image(systemName: isCompletedToday ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isCompletedToday ? .green : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            Text(habit.title)
                .font(.body)
                .foregroundStyle(isCompletedToday ? .secondary : .primary)
                .strikethrough(isCompletedToday)

            Spacer()
        }
        .padding(.vertical, Constants.Spacing.xs)
        .padding(.horizontal, Constants.Spacing.xs)
        .background(AppColors.background.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.sm))
    }
}

// MARK: - Needs Attention Row

struct NeedsAttentionRow: View {
    @Bindable var reminder: Reminder
    @State private var showingDetail = false

    var body: some View {
        HStack(alignment: .top, spacing: Constants.Spacing.xs) {
            // Completion toggle
            Button {
                withAnimation(Constants.Animation.spring) {
                    HapticManager.impact(.medium)
                    reminder.isCompleted.toggle()
                    if reminder.isCompleted {
                        reminder.completedAt = Date()
                    }
                }
            } label: {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(reminder.isCompleted ? .green : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            // Title
            Text(reminder.title)
                .font(.subheadline)
                .foregroundStyle(reminder.isCompleted ? .secondary : .primary)
                .strikethrough(reminder.isCompleted)
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture {
                    showingDetail = true
                }

            Spacer()

            // Snooze button
            Button {
                withAnimation(Constants.Animation.spring) {
                    HapticManager.impact(.light)
                    snoozeToTomorrow()
                }
            } label: {
                Text("Snooze")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, Constants.Spacing.xs)
        .background(AppColors.background)
        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.sm))
        .sheet(isPresented: $showingDetail) {
            ReminderDetailView(reminder: reminder)
        }
    }

    private func snoozeToTomorrow() {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        // Set to 9 AM tomorrow
        reminder.dueDate = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
    }
}

// MARK: - Home Category Section

struct HomeCategorySection: View {
    let category: Category
    let reminders: [Reminder]

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
            // Header
            NavigationLink {
                CategoryDetailView(category: category)
            } label: {
                HStack(spacing: Constants.Spacing.xs) {
                    Image(systemName: category.icon)
                        .foregroundStyle(category.color)
                    Text(category.name)
                        .font(.headline)
                    Spacer()
                    Text("\(reminders.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            // Reminders list
            VStack(spacing: 4) {
                ForEach(reminders) { reminder in
                    ReminderRow(reminder: reminder)
                }
            }
        }
        .padding(Constants.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Constants.CornerRadius.md)
                .fill(category.color.opacity(0.06))
        )
    }
}

// MARK: - Category Detail View

struct CategoryDetailView: View {
    let category: Category
    @Query private var reminders: [Reminder]

    private var categoryReminders: [Reminder] {
        reminders.filter { $0.category?.id == category.id && !$0.isCompleted }
            .sorted { r1, r2 in
                // Today/overdue items first, then by priority
                let r1Today = r1.isDueToday || r1.isOverdue
                let r2Today = r2.isDueToday || r2.isOverdue
                if r1Today != r2Today {
                    return r1Today
                }
                return r1.priority.rawValue > r2.priority.rawValue
            }
    }

    private var completedReminders: [Reminder] {
        reminders.filter { $0.category?.id == category.id && $0.isCompleted }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Constants.Spacing.sm) {
                if categoryReminders.isEmpty {
                    ContentUnavailableView(
                        "No Reminders",
                        systemImage: category.icon,
                        description: Text("Add reminders to \(category.name)")
                    )
                    .padding(.top, Constants.Spacing.xl)
                } else {
                    ForEach(categoryReminders) { reminder in
                        ReminderRow(reminder: reminder)
                    }
                }

                if !completedReminders.isEmpty {
                    Section {
                        ForEach(completedReminders) { reminder in
                            ReminderRow(reminder: reminder)
                        }
                    } header: {
                        HStack {
                            Text("Recently Completed")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.top, Constants.Spacing.lg)
                    }
                }
            }
            .padding()
        }
        .background(AppColors.background)
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.large)
    }
}

#Preview {
    TodayView()
        .modelContainer(for: [Reminder.self, Category.self], inMemory: true)
}
