import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var reminders: [Reminder]
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    // MARK: - Categorized Reminders (single-pass optimization)

    /// Categorizes all reminders in a single pass for better performance
    private var categorizedReminders: (habits: [Reminder], needsAttention: [Reminder], upcoming: [Reminder], byCategory: [UUID: [Reminder]]) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var habits: [Reminder] = []
        var needsAttention: [Reminder] = []
        var upcoming: [Reminder] = []
        var byCategory: [UUID: [Reminder]] = [:]

        for reminder in reminders {
            // Skip completed
            guard !reminder.isCompleted else { continue }

            // Habits go to their own list
            if reminder.isHabit {
                habits.append(reminder)
                continue
            }

            // Calculate days until due once
            let daysUntil: Int?
            if let dueDate = reminder.dueDate {
                let due = calendar.startOfDay(for: dueDate)
                daysUntil = calendar.dateComponents([.day], from: today, to: due).day
            } else {
                daysUntil = nil
            }

            let isOverdue = daysUntil.map { $0 < 0 } ?? false
            let isDueToday = daysUntil == 0
            let isUpcoming = daysUntil.map { $0 >= 1 && $0 <= 2 } ?? false

            if isOverdue || isDueToday {
                needsAttention.append(reminder)
            } else if isUpcoming {
                upcoming.append(reminder)
            } else if let categoryId = reminder.category?.id {
                byCategory[categoryId, default: []].append(reminder)
            }
        }

        // Sort each list
        habits.sort { $0.title < $1.title }
        needsAttention.sort { r1, r2 in
            if r1.isOverdue != r2.isOverdue { return r1.isOverdue }
            if r1.isDueToday != r2.isDueToday { return r1.isDueToday }
            return r1.priority.rawValue > r2.priority.rawValue
        }
        upcoming.sort { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        for key in byCategory.keys {
            byCategory[key]?.sort { $0.priority.rawValue > $1.priority.rawValue }
        }

        return (habits, needsAttention, upcoming, byCategory)
    }

    @State private var searchText = ""

    // MARK: - Search Filtered Results (uses cached categorization)

    /// All filtered data computed once, accessed via single property
    private var filteredData: FilteredReminderData {
        let cached = categorizedReminders

        // Apply search filter
        let filterBlock: (Reminder) -> Bool = searchText.isEmpty ? { _ in true } : { reminder in
            reminder.title.localizedCaseInsensitiveContains(searchText) ||
            reminder.notes.localizedCaseInsensitiveContains(searchText)
        }

        let habits = cached.habits.filter(filterBlock)
        let needsAttention = cached.needsAttention.filter(filterBlock)
        let upcoming = cached.upcoming.filter(filterBlock)

        // Group needs attention by category
        var grouped: [UUID?: [Reminder]] = [:]
        for reminder in needsAttention {
            grouped[reminder.category?.id, default: []].append(reminder)
        }

        var needsAttentionByCategory: [(category: Category?, reminders: [Reminder])] = []
        for category in categories {
            if let reminders = grouped[category.id], !reminders.isEmpty {
                needsAttentionByCategory.append((category: category, reminders: reminders))
            }
        }
        if let uncategorized = grouped[nil], !uncategorized.isEmpty {
            needsAttentionByCategory.append((category: nil, reminders: uncategorized))
        }

        // Filter category reminders
        var byCategory: [UUID: [Reminder]] = [:]
        for (key, value) in cached.byCategory {
            let filtered = value.filter(filterBlock)
            if !filtered.isEmpty {
                byCategory[key] = filtered
            }
        }

        return FilteredReminderData(
            habits: habits,
            needsAttention: needsAttention,
            upcoming: upcoming,
            needsAttentionByCategory: needsAttentionByCategory,
            byCategory: byCategory
        )
    }

    private struct FilteredReminderData {
        let habits: [Reminder]
        let needsAttention: [Reminder]
        let upcoming: [Reminder]
        let needsAttentionByCategory: [(category: Category?, reminders: [Reminder])]
        let byCategory: [UUID: [Reminder]]
    }

    // Convenience accessors that use the cached filteredData
    private var searchFilteredHabits: [Reminder] { filteredData.habits }
    private var searchFilteredNeedsAttention: [Reminder] { filteredData.needsAttention }
    private var searchFilteredUpcoming: [Reminder] { filteredData.upcoming }
    private var searchFilteredNeedsAttentionByCategory: [(category: Category?, reminders: [Reminder])] { filteredData.needsAttentionByCategory }

    private func searchFilteredRemindersForCategory(_ category: Category) -> [Reminder] {
        filteredData.byCategory[category.id] ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: Constants.Spacing.sm) {
                    // Habits Section - Daily Checklist
                    if !searchFilteredHabits.isEmpty {
                        HabitsSection(habits: searchFilteredHabits)
                    }

                    // Urgent / Time-sensitive / High Priority - grouped by category
                    if !searchFilteredNeedsAttention.isEmpty {
                        VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
                            HStack(spacing: Constants.Spacing.xs) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.red)
                                Text("Needs Attention")
                                    .font(.headline)
                            }

                            VStack(spacing: Constants.Spacing.md) {
                                ForEach(Array(searchFilteredNeedsAttentionByCategory.enumerated()), id: \.offset) { _, group in
                                        VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
                                            // Category header
                                            if let category = group.category {
                                                HStack(spacing: 4) {
                                                    Image(systemName: category.icon)
                                                        .font(.caption)
                                                    Text(category.name)
                                                        .font(.caption)
                                                        .fontWeight(.medium)
                                                }
                                                .foregroundStyle(category.color)
                                            } else {
                                                Text("Uncategorized")
                                                    .font(.caption)
                                                    .fontWeight(.medium)
                                                    .foregroundStyle(.secondary)
                                            }

                                            // Reminders in this category
                                            ForEach(group.reminders) { reminder in
                                                NeedsAttentionRow(reminder: reminder)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(Constants.Spacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: Constants.CornerRadius.md)
                                    .fill(Color.red.opacity(0.08))
                            )
                        }

                    // Upcoming - due in the next 2 days
                    if !searchFilteredUpcoming.isEmpty {
                        VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
                            HStack(spacing: Constants.Spacing.xs) {
                                Image(systemName: "calendar.badge.clock")
                                    .foregroundStyle(.blue)
                                Text("Upcoming")
                                    .font(.headline)
                                Spacer()
                                Text("\(searchFilteredUpcoming.count)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            ForEach(searchFilteredUpcoming) { reminder in
                                    UpcomingReminderRow(reminder: reminder)
                                }
                            }
                            .padding(Constants.Spacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: Constants.CornerRadius.md)
                                    .fill(Color.blue.opacity(0.08))
                            )
                        }

                    // Categories with reminders
                    ForEach(categories.filter { $0.name != "Habits" }) { category in
                        let categoryReminders = searchFilteredRemindersForCategory(category)
                        if !categoryReminders.isEmpty {
                            HomeCategorySection(
                                category: category,
                                reminders: categoryReminders
                            )
                        }
                    }

                    // Empty state when searching
                    if !searchText.isEmpty &&
                       searchFilteredHabits.isEmpty &&
                       searchFilteredNeedsAttention.isEmpty &&
                       searchFilteredUpcoming.isEmpty &&
                       categories.allSatisfy({ searchFilteredRemindersForCategory($0).isEmpty }) {
                        ContentUnavailableView(
                            "No Results",
                            systemImage: "magnifyingglass",
                            description: Text("No reminders match \"\(searchText)\"")
                        )
                        .padding(.top, Constants.Spacing.xl)
                    }
                }
                .padding()
            }
            .background(AppColors.background)
            .navigationTitle("Gentle Nudge")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .searchable(text: $searchText, prompt: "Search reminders")
        }
    }
}

// MARK: - Habits Section

struct HabitsSection: View {
    let habits: [Reminder]

    private var completedCount: Int {
        habits.filter { $0.isCompletedToday }.count
    }

    private let habitColor: Color = .teal

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
            HStack {
                Image(systemName: "leaf.circle.fill")
                    .foregroundStyle(habitColor)
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
                        .fill(habitColor.opacity(0.2))
                        .frame(height: 5)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(habitColor)
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
                .fill(Color.teal.opacity(0.10))
        )
    }
}

struct HabitRow: View {
    @Bindable var habit: Reminder
    @State private var showingHeatmap = false

    var isCompletedToday: Bool {
        habit.isCompletedToday
    }

    private var currentStreak: Int {
        let calendar = Calendar.current
        var streak = 0
        var checkDate = calendar.startOfDay(for: Date())

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

            // Streak indicator
            if currentStreak > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "flame.fill")
                        .font(.caption2)
                    Text("\(currentStreak)")
                        .font(.caption2)
                        .fontWeight(.medium)
                }
                .foregroundStyle(.orange)
            }

            #if os(iOS)
            // Mini heatmap (last 14 days)
            HabitMiniHeatmap(habit: habit, days: 14)
            #endif
        }
        .padding(.vertical, Constants.Spacing.xs)
        .padding(.horizontal, Constants.Spacing.xs)
        .background(AppColors.background.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.sm))
        #if os(iOS)
        .contentShape(Rectangle())
        .onTapGesture {
            showingHeatmap = true
        }
        .sheet(isPresented: $showingHeatmap) {
            HabitDetailSheet(habit: habit)
        }
        #endif
    }
}

#if os(iOS)
struct HabitDetailSheet: View {
    @Bindable var habit: Reminder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Constants.Spacing.lg) {
                    HabitHeatmapView(habit: habit, weeks: 16)

                    // Stats
                    VStack(spacing: Constants.Spacing.sm) {
                        HabitStatRow(title: "Last 7 days", value: "\(habit.completionCount(days: 7))/7")
                        HabitStatRow(title: "Last 30 days", value: "\(habit.completionCount(days: 30))/30")
                        HabitStatRow(title: "Total completions", value: "\(habit.habitCompletionDates.count)")
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: Constants.CornerRadius.md)
                            .fill(Color.secondary.opacity(0.1))
                    )
                }
                .padding()
            }
            .background(AppColors.background)
            .navigationTitle(habit.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct HabitStatRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
    }
}
#endif

// MARK: - Upcoming Reminder Row

struct UpcomingReminderRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var reminder: Reminder
    @State private var showingDetail = false

    private var daysUntilText: String {
        guard let days = reminder.daysUntilDue else { return "" }
        if days == 1 { return "Tomorrow" }
        return "in \(days) days"
    }

    var body: some View {
        HStack(spacing: Constants.Spacing.sm) {
            // Completion toggle
            Button {
                withAnimation(Constants.Animation.spring) {
                    HapticManager.impact(.medium)
                    if reminder.isCompleted {
                        reminder.markIncomplete()
                    } else {
                        completeReminder()
                    }
                }
            } label: {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(reminder.isCompleted ? .green : .secondary)
            }
            .buttonStyle(.plain)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(.subheadline)
                    .lineLimit(1)

                HStack(spacing: Constants.Spacing.xs) {
                    // Category
                    if let category = reminder.category {
                        HStack(spacing: 2) {
                            Image(systemName: category.icon)
                                .font(.system(size: 10))
                            Text(category.name)
                                .font(.caption2)
                        }
                        .foregroundStyle(category.color)
                    }

                    // Due date
                    Text(daysUntilText)
                        .font(.caption2)
                        .foregroundStyle(.blue)

                    // Recurrence badge
                    if reminder.isRecurring {
                        RecurrenceBadge(recurrence: reminder.recurrence, compact: true)
                    }
                }
            }

            Spacer()

            // Priority indicator
            if reminder.priority == .urgent {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, Constants.Spacing.xs)
        .padding(.horizontal, Constants.Spacing.xs)
        .background(AppColors.background.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.sm))
        .contentShape(Rectangle())
        .onTapGesture {
            showingDetail = true
        }
        .sheet(isPresented: $showingDetail) {
            NavigationStack {
                ReminderDetailView(reminder: reminder)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func completeReminder() {
        reminder.complete(in: modelContext)
    }
}

// MARK: - Needs Attention Row

struct NeedsAttentionRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var reminder: Reminder
    @State private var showingDetail = false

    var body: some View {
        HStack(alignment: .top, spacing: Constants.Spacing.xs) {
            // Completion toggle
            Button {
                withAnimation(Constants.Animation.spring) {
                    HapticManager.impact(.medium)
                    if reminder.isCompleted {
                        reminder.markIncomplete()
                    } else {
                        completeReminder()
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

            // Title and metadata
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(.subheadline)
                    .foregroundStyle(reminder.isCompleted ? .secondary : .primary)
                    .strikethrough(reminder.isCompleted)
                    .fixedSize(horizontal: false, vertical: true)

                // Due date and recurrence info (category shown in group header)
                HStack(spacing: 6) {
                    if let dueDate = reminder.dueDate {
                        Text(formatDate(dueDate))
                            .font(.caption2)
                            .foregroundStyle(dateColor(dueDate))
                    }

                    if reminder.isRecurring {
                        RecurrenceBadge(recurrence: reminder.recurrence)
                    }
                }
            }
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
        .padding(.vertical, 10)
        .padding(.horizontal, Constants.Spacing.sm)
        .background(AppColors.background)
        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.sm))
        .sheet(isPresented: $showingDetail) {
            ReminderDetailView(reminder: reminder)
        }
    }

    private func completeReminder() {
        reminder.complete(in: modelContext)
    }

    private func snoozeToTomorrow() {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        // Set to 9 AM tomorrow
        reminder.dueDate = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
    }

    private func formatDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Today"
        }
        if Calendar.current.isDateInTomorrow(date) {
            return "Tomorrow"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func dateColor(_ date: Date) -> Color {
        if date < Date() { return .red }
        if Calendar.current.isDateInToday(date) { return .orange }
        return .secondary
    }
}

// MARK: - Home Category Section

struct HomeCategorySection: View {
    let category: Category
    let reminders: [Reminder]

    // Active: non-recurring, or recurring that's due soon (within 3 days)
    private var activeReminders: [Reminder] {
        reminders.filter { !$0.isDistantRecurring }
            .sorted { r1, r2 in
                // Due soon first, then by priority
                if r1.isDueToday != r2.isDueToday { return r1.isDueToday }
                if r1.isOverdue != r2.isOverdue { return r1.isOverdue }
                return r1.priority.rawValue > r2.priority.rawValue
            }
    }

    // Upcoming: recurring items due later (muted)
    private var upcomingRecurring: [Reminder] {
        reminders.filter { $0.isDistantRecurring }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

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

            // Active reminders
            if !activeReminders.isEmpty {
                VStack(spacing: 4) {
                    ForEach(activeReminders) { reminder in
                        ReminderRow(reminder: reminder)
                    }
                }
            }

            // Upcoming recurring (collapsed section)
            if !upcomingRecurring.isEmpty {
                DisclosureGroup {
                    VStack(spacing: 4) {
                        ForEach(upcomingRecurring) { reminder in
                            ReminderRow(reminder: reminder)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "repeat")
                            .font(.caption2)
                        Text("Upcoming (\(upcomingRecurring.count))")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .tint(.secondary)
            }
        }
        .padding(Constants.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Constants.CornerRadius.md)
                .fill(category.color.opacity(0.10))
        )
    }
}

// MARK: - Category Detail View

struct CategoryDetailView: View {
    let category: Category
    @Query private var reminders: [Reminder]

    // Active: non-recurring, or recurring due soon
    private var activeReminders: [Reminder] {
        reminders.filter { $0.category?.id == category.id && !$0.isCompleted && !$0.isDistantRecurring }
            .sorted { r1, r2 in
                if r1.isDueToday != r2.isDueToday { return r1.isDueToday }
                if r1.isOverdue != r2.isOverdue { return r1.isOverdue }
                return r1.priority.rawValue > r2.priority.rawValue
            }
    }

    // Upcoming recurring
    private var upcomingRecurring: [Reminder] {
        reminders.filter { $0.category?.id == category.id && !$0.isCompleted && $0.isDistantRecurring }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    private var completedReminders: [Reminder] {
        reminders.filter { $0.category?.id == category.id && $0.isCompleted }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(5)
            .map { $0 }
    }

    private var hasAnyReminders: Bool {
        !activeReminders.isEmpty || !upcomingRecurring.isEmpty
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Constants.Spacing.sm) {
                if !hasAnyReminders {
                    ContentUnavailableView(
                        "No Reminders",
                        systemImage: category.icon,
                        description: Text("Add reminders to \(category.name)")
                    )
                    .padding(.top, Constants.Spacing.xl)
                } else {
                    // Active reminders
                    if !activeReminders.isEmpty {
                        Section {
                            ForEach(activeReminders) { reminder in
                                ReminderRow(reminder: reminder)
                            }
                        } header: {
                            if !upcomingRecurring.isEmpty {
                                HStack {
                                    Text("Active")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                            }
                        }
                    }

                    // Upcoming recurring
                    if !upcomingRecurring.isEmpty {
                        Section {
                            ForEach(upcomingRecurring) { reminder in
                                ReminderRow(reminder: reminder)
                            }
                        } header: {
                            HStack(spacing: 4) {
                                Image(systemName: "repeat")
                                    .font(.caption)
                                Text("Upcoming Recurring")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Spacer()
                                Text("\(upcomingRecurring.count)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.top, activeReminders.isEmpty ? 0 : Constants.Spacing.md)
                        }
                    }
                }

                // Recently completed
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
    }
}

#Preview {
    TodayView()
        .modelContainer(for: [Reminder.self, Category.self], inMemory: true)
}
