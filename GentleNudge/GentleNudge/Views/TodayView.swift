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

    // Urgent: Items due today but NOT overdue yet
    private var urgentReminders: [Reminder] {
        reminders.filter { reminder in
            guard !reminder.isHabit, !reminder.isCompleted else { return false }
            guard reminder.dueDate != nil else { return false }
            // Due today but not yet overdue (to avoid duplicates with overdueReminders)
            return reminder.isDueToday && !reminder.isOverdue
        }
        .sorted { $0.priority.rawValue > $1.priority.rawValue }
    }

    // Overdue (excluding habits)
    private var overdueReminders: [Reminder] {
        reminders.filter { $0.isOverdue && !$0.isCompleted && !$0.isHabit }
            .sorted { $0.priority.rawValue > $1.priority.rawValue }
    }

    private func remindersForCategory(_ category: Category) -> [Reminder] {
        reminders.filter {
            $0.category?.id == category.id &&
            !$0.isCompleted &&
            !$0.isHabit
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
                    LazyVStack(spacing: Constants.Spacing.lg) {
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

                        // Urgent / Time-sensitive
                        if !overdueReminders.isEmpty || !urgentReminders.isEmpty {
                            VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
                                HStack(spacing: Constants.Spacing.xs) {
                                    Image(systemName: "clock.badge.exclamationmark.fill")
                                        .foregroundStyle(.red)
                                    Text("Needs Attention")
                                        .font(.headline)
                                }
                                .padding(.horizontal, Constants.Spacing.xs)

                                VStack(spacing: Constants.Spacing.xs) {
                                    ForEach(overdueReminders + urgentReminders) { reminder in
                                        NeedsAttentionRow(reminder: reminder)
                                    }
                                }
                            }
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
                Text("Daily Habits")
                    .font(.headline)
                Spacer()
                Text("\(completedCount)/\(habits.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Constants.Spacing.xs)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.red.opacity(0.2))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.red)
                        .frame(width: geo.size.width * CGFloat(completedCount) / CGFloat(max(habits.count, 1)), height: 8)
                        .animation(.spring, value: completedCount)
                }
            }
            .frame(height: 8)
            .padding(.horizontal, Constants.Spacing.xs)

            VStack(spacing: Constants.Spacing.xxs) {
                ForEach(habits) { habit in
                    HabitRow(habit: habit)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: Constants.CornerRadius.lg)
                .fill(Color.red.opacity(0.08))
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
                    .font(.title2)
                    .foregroundStyle(isCompletedToday ? .green : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            Text(habit.title)
                .font(.body)
                .foregroundStyle(isCompletedToday ? .secondary : .primary)
                .strikethrough(isCompletedToday)

            Spacer()

            if !habit.notes.isEmpty {
                Text(habit.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, Constants.Spacing.xs)
        .padding(.horizontal, Constants.Spacing.sm)
        .background(AppColors.background.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.sm))
    }
}

// MARK: - Needs Attention Row

struct NeedsAttentionRow: View {
    @Bindable var reminder: Reminder
    @State private var showingDetail = false

    var body: some View {
        HStack(spacing: Constants.Spacing.sm) {
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
                    .font(.title2)
                    .foregroundStyle(reminder.isCompleted ? .green : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            // Title and details
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(.body)
                    .foregroundStyle(reminder.isCompleted ? .secondary : .primary)
                    .strikethrough(reminder.isCompleted)
                    .lineLimit(1)

                if let dueDate = reminder.dueDate {
                    Text(dueDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(reminder.isOverdue ? .red : .secondary)
                }
            }
            .onTapGesture {
                showingDetail = true
            }

            Spacer()

            // Tomorrow button
            Button {
                withAnimation(Constants.Animation.spring) {
                    HapticManager.impact(.light)
                    postponeToTomorrow()
                }
            } label: {
                Text("Tomorrow")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Constants.Spacing.sm)
                    .padding(.vertical, Constants.Spacing.xs)
                    .background(Color.orange)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, Constants.Spacing.xs)
        .padding(.horizontal, Constants.Spacing.sm)
        .background(AppColors.background)
        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.sm))
        .sheet(isPresented: $showingDetail) {
            ReminderDetailView(reminder: reminder)
        }
    }

    private func postponeToTomorrow() {
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
            .padding(.horizontal, Constants.Spacing.xs)

            // Reminders list
            VStack(spacing: Constants.Spacing.xs) {
                ForEach(reminders) { reminder in
                    ReminderRow(reminder: reminder)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: Constants.CornerRadius.lg)
                .fill(category.color.opacity(0.08))
        )
    }
}

// MARK: - Category Detail View

struct CategoryDetailView: View {
    let category: Category
    @Query private var reminders: [Reminder]

    private var categoryReminders: [Reminder] {
        reminders.filter { $0.category?.id == category.id && !$0.isCompleted }
            .sorted { $0.priority.rawValue > $1.priority.rawValue }
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
